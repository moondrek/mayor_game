defmodule MayorGame.CityMigrator do
  use GenServer, restart: :permanent
  alias MayorGame.City.{Town, Citizens, Buildable, TownStatistics, ResourceStatistics}
  alias MayorGame.{City, CityHelpers, Repo, Rules}
  import Ecto.Query

  def start_link(initial_val) do
    IO.puts('start_city_migrator_link')
    # starts link based on this file
    # which triggers init function in module

    # check here if world exists already
    case City.get_world(initial_val) do
      %City.World{} -> IO.puts("world exists already!")
      nil -> City.create_world(%{day: 0, pollution: 0})
    end

    # this calls init function
    GenServer.start_link(__MODULE__, initial_val)
  end

  def init(initial_world) do
    buildables_map = %{
      buildables_flat: Buildable.buildables_flat(),
      buildables: Buildable.buildables(),
      buildables_list: Buildable.buildables_list(),
      buildables_ordered: Buildable.buildables_ordered()
    }

    in_dev = Application.get_env(:mayor_game, :env) == :dev

    IO.puts('init migrator')
    # initial_val is 1 here, set in application.ex then started with start_link

    game_world = City.get_world!(initial_world)

    # send message :tax to self process after
    # calls `handle_info` function
    Process.send_after(self(), :tax, 5000)

    # returns ok tuple when u start
    {:ok, %{world: game_world, buildables_map: buildables_map, in_dev: in_dev, migration_tick: 0}}
  end

  # when :tax is sent
  def handle_info(
        :tax,
        %{
          world: world,
          buildables_map: buildables_map,
          in_dev: in_dev,
          migration_tick: migration_tick
        } = _sent_map
      ) do
    # profiling
    {:ok, datetime_pre} = DateTime.now("Etc/UTC")

    # filter for

    cities = CityHelpers.prepare_cities(datetime_pre, world.day, in_dev)

    pollution_ceiling = 2_000_000_000 * Random.gammavariate(7.5, 1)

    db_world = City.get_world!(1)

    if length(cities) > 0 do
      season = Rules.season_from_day(db_world.day)

      cities_list = Enum.shuffle(cities)

      time_to_learn = if in_dev, do: rem(migration_tick, 5) == 0, else: rem(migration_tick, 100) == 0
      if time_to_learn, do: IO.inspect("learning time")

      leftovers =
        cities_list
        |> Enum.map(fn city ->
          # result here is a %Town{} with stats calculated
          city_stat =
            CityHelpers.calculate_city_stats_with_drops(
              city,
              db_world,
              pollution_ceiling,
              season,
              buildables_map,
              in_dev,
              time_to_learn
            )

          leftover =
            CityHelpers.calculate_citizen_stats(
              city,
              city_stat,
              db_world,
              pollution_ceiling,
              season,
              buildables_map,
              in_dev,
              time_to_learn
            )

          # if city.id == 2 do
          #   IO.inspect(length(leftover.staying_citizens), label: "staying_citizens")
          #   IO.inspect(length(leftover.migrating_citizens_due_to_tax), label: "migrating_citizens_due_to_tax")
          #   IO.inspect(length(leftover.migrating_citizens), label: "migrating_citizens")
          #   IO.inspect(length(leftover.unemployed_citizens), label: "unemployed_citizens")
          #   IO.inspect(length(leftover.unhoused_citizens), label: "unhoused_citizens")
          #   IO.inspect(length(leftover.polluted_citizens), label: "polluted_citizens")

          # end

          # combine town and the calculated stats (TownStatistics + TownMigrationStatistics)
          city |> Map.merge(city_stat) |> Map.merge(leftover)
        end)

      employed_looking_citizens =
        List.flatten(
          Enum.map(leftovers, fn city ->
            city.migrating_citizens ++ city.migrating_citizens_due_to_tax
          end)
        )

      unemployed_citizens = List.flatten(Enum.map(leftovers, fn city -> city.unemployed_citizens end))

      unhoused_citizens = List.flatten(Enum.map(leftovers, fn city -> city.unhoused_citizens end))

      housing_slots = Enum.map(leftovers, fn city -> {city.id, city.housing_left} end) |> Map.new()

      # ok this is still good

      sprawl_max =
        Enum.max(
          Enum.map(leftovers, fn city ->
            city |> TownStatistics.getResource(:sprawl) |> ResourceStatistics.getNetProduction()
          end)
        )

      pollution_enum =
        Enum.map(leftovers, fn city ->
          city |> TownStatistics.getResource(:pollution) |> ResourceStatistics.getNetProduction()
        end)

      pollution_max = Enum.max(pollution_enum)
      pollution_min = Enum.min(pollution_enum)
      pollution_spread = pollution_max - pollution_min

      fun_max =
        Enum.max(
          Enum.map(leftovers, fn city ->
            city |> TownStatistics.getResource(:fun) |> ResourceStatistics.getNetProduction()
          end)
        )

      culture_max =
        Enum.max(
          Enum.map(leftovers, fn city ->
            city |> TownStatistics.getResource(:culture) |> ResourceStatistics.getNetProduction()
          end)
        )

      crime_max =
        Enum.max(
          Enum.map(leftovers, fn city ->
            city |> TownStatistics.getResource(:crime) |> ResourceStatistics.getNetProduction()
          end)
        )

      health_enum =
        Enum.map(leftovers, fn city ->
          city |> TownStatistics.getResource(:health) |> ResourceStatistics.getNetProduction()
        end)

      health_max = Enum.max(health_enum)
      health_min = Enum.min(health_enum)
      health_spread = health_max - health_min

      home_city_advantage = 0.05

      slotted_cities_by_id =
        leftovers
        |> Enum.map(fn city ->
          normalize_city(
            city,
            fun_max,
            health_spread,
            pollution_spread,
            sprawl_max,
            culture_max,
            crime_max
          )
        end)
        |> Map.new(fn city ->
          {city.id, city}
        end)

      city_preference_scores =
        Enum.map(1..11, fn x ->
          {x,
           Enum.map(0..5, fn edu_level ->
             {edu_level,
              Enum.map(slotted_cities_by_id, fn {id, city} ->
                {id,
                 Float.round(
                   citizen_score(
                     Citizens.preset_preferences()[x],
                     edu_level,
                     city
                   ),
                   4
                 )}
              end)
              |> Enum.into(%{})}
           end)
           |> Enum.into(%{})}
        end)
        |> Enum.into(%{})

      # jobs still valid here
      # and housing

      updated_citizens_by_id =
        leftovers
        |> Map.new(fn city -> {city.id, city.staying_citizens} end)

      # the TownMigrationStatistics part of the map contains all categorized citizens
      # Those that take part in migration are
      #   migrating_citizens_due_to_tax: [],
      #   migrating_citizens: [],
      #   unemployed_citizens: [],
      #   unhoused_citizens: [],

      # ——————————————————————————————————————————————————————————————————————————————————
      # ————————————————————————————————————————— ROUND 1: MOVE CITIZENS PER JOB LEVEL
      # ——————————————————————————————————————————————————————————————————————————————————

      level_slots =
        Map.new(0..5, fn x ->
          {x, %{normalized_cities: %{}, job_and_housing_slots: 0, job_and_housing_slots_expanded: []}}
        end)

      # sets up empty map for below function
      # SHAPE OF BELOW:
      # %{
      #   1: %{normalized_cities: [
      #     {city_normalized, # of slots}, {city_normalized, # of slots}
      #   ],
      #     total_slots: int,
      #     job_and_housing_slots_expanded: list of slots
      #   }
      # }
      # all_cities_by_id = maybe make a map here of city in all_cities_new and their id
      # or all_cities_new might already be that, by index
      # or the map is just of the ones with housing slots (e.g. in housing_slots)
      # all_cities_by_id =
      #   leftovers
      #   |> Map.new(fn city -> {city.id, city} end)

      # NO FLOW

      # housing_slots is a list of {city, number of slots}
      # try FLOW here with a partition + reduce
      # do a bunch of the housing calcs with ETS? instead of mapping over a map accumulator, put it in ets and manipulate it there?

      job_and_housing_slots_normalized =
        Enum.reduce(
          housing_slots,
          level_slots,
          fn {normalized_city_id, housing_slots_count}, acc ->
            slots_per_level =
              Enum.reduce(
                slotted_cities_by_id[normalized_city_id].jobs,
                %{housing_slots_left: housing_slots_count},
                fn {level, count}, acc2 ->
                  if acc2.housing_slots_left > 0 do
                    level_slots_count = min(count, acc2.housing_slots_left)

                    acc2
                    |> Map.update!(
                      :housing_slots_left,
                      &(&1 - level_slots_count)
                    )
                    |> Map.put(level, {normalized_city_id, level_slots_count})
                  else
                    acc2
                    |> Map.put(level, {normalized_city_id, 0})
                  end
                end
              )
              |> Map.drop([:housing_slots_left])

            # each value is [{city, count}]
            # slots_taken_w_job = Enum.sum(Map.values(slots_per_level))
            # slots_taken_w_job = Enum.sum(Keyword.values(Map.values(slots_per_level)))

            # for each level in slots_per_level
            #
            level_results =
              Enum.map(5..0, fn x ->
                {x,
                 %{
                   normalized_cities:
                     Map.put(
                       acc[x].normalized_cities,
                       elem(slots_per_level[x], 0),
                       elem(slots_per_level[x], 1)
                     ),

                   #  acc[x].normalized_cities ++ [slots_per_level[x]],
                   job_and_housing_slots: acc[x].job_and_housing_slots + elem(slots_per_level[x], 1),
                   job_and_housing_slots_expanded:
                     if elem(slots_per_level[x], 1) > 0 do
                       acc[x].job_and_housing_slots_expanded ++
                         Enum.map(1..elem(slots_per_level[x], 1), fn _ -> normalized_city_id end)
                     else
                       acc[x].job_and_housing_slots_expanded
                     end
                 }}
              end)
              |> Enum.into(%{})

            level_results
          end
        )

      # split by who will get to take the good slots
      # shape is map with key level, tuple
      # %{
      #   0 => {[citizens_searching], [citizens_not]},
      #   1 => {[citizens_searching], [citizens_not]},
      # }
      employed_citizens_split =
        Map.new(5..0, fn x ->
          {x,
           Enum.split(
             Enum.filter(employed_looking_citizens, fn cit -> cit["education"] == x end),
             job_and_housing_slots_normalized[x].job_and_housing_slots
           )}
        end)

      preferred_locations_by_level =
        Map.new(5..0, fn level ->
          {level,
           Enum.reduce(
             elem(employed_citizens_split[level], 0),
             %{
               choices: [],
               slots: job_and_housing_slots_normalized[level].normalized_cities
             },
             fn citizen, acc ->
               current_city_score =
                 city_preference_scores[citizen["preferences"]][citizen["education"]][
                   citizen["town_id"]
                 ]

               chosen_city =
                 Enum.reduce(
                   acc.slots,
                   %{chosen_id: citizen["town_id"], top_score: -1},
                   fn {city_id, count}, acc2 ->
                     score =
                       if count > 0 do
                         city_preference_scores[citizen["preferences"]][citizen["education"]][
                           city_id
                         ]
                       else
                         0
                       end

                     if score > acc2.top_score && score > current_city_score + home_city_advantage do
                       %{
                         chosen_id: city_id,
                         top_score: score
                       }
                     else
                       acc2
                     end
                   end
                 )

               updated_slots =
                 acc.slots
                 |> Map.update(chosen_city.chosen_id, 0, &(&1 - 1))
                 |> Map.update(citizen["town_id"], 0, &(&1 + 1))

               %{
                 choices: [{citizen, chosen_city.chosen_id} | acc.choices],
                 slots: updated_slots
               }
             end
           )}
        end)

      # find a way to return these to origin city
      looking_but_not_in_job_race =
        Enum.reduce(employed_citizens_split, [], fn {_k, v}, acc ->
          List.flatten([elem(v, 1) | acc])
        end)

      # ^ array of citizens who are still looking, that didn't make it into the level-specific comparisons

      # update the citizen's choice
      updated_citizens_by_id_2 =
        Enum.reduce(5..0, updated_citizens_by_id, fn x, acc ->
          if preferred_locations_by_level[x].choices != [] do
            Enum.reduce(preferred_locations_by_level[x].choices, acc, fn {citizen, chosen_city_id}, acc2 ->
              if citizen["town_id"] != chosen_city_id do
                acc2
                |> Map.update!(
                  chosen_city_id,
                  &[
                    citizen
                    |> Map.take(["education", "preferences", "age"])
                    | &1
                  ]
                )
              else
                acc2
                |> Map.update!(
                  chosen_city_id,
                  &[citizen |> Map.take(["education", "preferences", "age"]) | &1]
                )
              end
            end)
          else
            acc
          end
        end)

      # add non-lookers back
      updated_citizens_by_id_3 =
        if looking_but_not_in_job_race != [] do
          Enum.reduce(looking_but_not_in_job_race, updated_citizens_by_id_2, fn citizen, acc ->
            acc
            |> Map.update!(
              citizen["town_id"],
              &[citizen |> Map.take(["education", "preferences", "age"]) | &1]
            )
          end)
        else
          updated_citizens_by_id_2
        end

      vacated_slots =
        Enum.flat_map(preferred_locations_by_level, fn {_level, preferred_locations} ->
          preferred_locations.choices
          |> Enum.filter(fn {citizen, city_id} -> citizen["town_id"] != city_id end)
          |> Enum.map(fn {citizen, _city_id} -> citizen["town_id"] end)
        end)

      occupied_slots =
        Enum.flat_map(preferred_locations_by_level, fn {_level, preferred_locations} ->
          preferred_locations.choices
          |> Enum.filter(fn {citizen, city_id} -> citizen["town_id"] != city_id end)
          |> Enum.map(fn {_citizen, city_id} -> city_id end)
        end)

      vacated_freq = Enum.frequencies(vacated_slots)
      occupied_freq = Enum.frequencies(occupied_slots)

      housing_slots_2 =
        housing_slots
        |> Map.merge(vacated_freq, fn _k, v1, v2 -> v1 + v2 end)
        |> Map.merge(occupied_freq, fn _k, v1, v2 -> v1 - v2 end)

      # NEW UNEMPLOYED CODE ————————————————————————————————————————————————————————————————————————————
      # ————————————————————————————————————————————————————————————————————————————
      # ————————————————————————————————————————————————————————————————————————————
      # ————————————————————————————————————————————————————————————————————————————
      # ————————————————————————————————————————————————————————————————————————————

      unemployed_citizens_split =
        Map.new(5..0, fn x ->
          {x,
           Enum.split(
             Enum.filter(unemployed_citizens, fn cit -> cit["education"] == x end),
             Enum.sum(Map.values(preferred_locations_by_level[x].slots))
           )}
        end)

      unemployed_preferred_locations_by_level =
        Map.new(5..0, fn level ->
          {level,
           Enum.reduce(
             elem(unemployed_citizens_split[level], 0),
             %{
               choices: [],
               slots: preferred_locations_by_level[level].slots
             },
             fn citizen, acc ->
               chosen_city =
                 Enum.reduce(
                   acc.slots,
                   %{
                     chosen_id: citizen["town_id"],
                     top_score: -1
                   },
                   fn {city_id, count}, acc2 ->
                     score =
                       if count > 0 && city_id != citizen["town_id"] do
                         city_preference_scores[citizen["preferences"]][citizen["education"]][
                           city_id
                         ]
                       else
                         0
                       end

                     if score > acc2.top_score do
                       %{
                         chosen_id: city_id,
                         top_score: score
                       }
                     else
                       acc2
                     end
                   end
                 )

               updated_slots =
                 acc.slots
                 |> Map.update(chosen_city.chosen_id, 0, &(&1 - 1))

               %{
                 choices: [{citizen, chosen_city.chosen_id} | acc.choices],
                 slots: updated_slots
               }
             end
           )}
        end)

      # find a way to return these to origin city
      unemployed_split_2 =
        Enum.reduce(unemployed_citizens_split, [], fn {_k, v}, acc ->
          List.flatten([elem(v, 1) | acc])
        end)

      # update the citizen's choice
      updated_citizens_by_id_4 =
        Enum.reduce(5..0, updated_citizens_by_id_3, fn x, acc ->
          # if unemployed_preferred_locations_by_level[x].choices != [] do
          Enum.reduce(unemployed_preferred_locations_by_level[x].choices, acc, fn {citizen, chosen_city_id}, acc2 ->
            if citizen["town_id"] != chosen_city_id do
              acc2
              |> Map.update!(
                chosen_city_id,
                &[
                  citizen
                  |> Map.take(["education", "preferences", "age"])
                  | &1
                ]
              )
            else
              acc2
              |> Map.update!(
                chosen_city_id,
                &[citizen |> Map.take(["education", "preferences", "age"]) | &1]
              )
            end
          end)

          # else
          # acc
          # end
        end)

      # add non-lookers back
      updated_citizens_by_id_5 =
        if unemployed_split_2 != [] do
          Enum.reduce(unemployed_split_2, updated_citizens_by_id_4, fn citizen, acc ->
            acc
            |> Map.update!(
              citizen["town_id"],
              &[
                citizen |> Map.take(["education", "preferences", "age"]) | &1
              ]
            )
          end)
        else
          updated_citizens_by_id_4
        end

      vacated_slots_2 =
        Enum.flat_map(unemployed_preferred_locations_by_level, fn {_level, preferred_locations} ->
          preferred_locations.choices
          |> Enum.filter(fn {citizen, city_id} -> citizen["town_id"] != city_id end)
          |> Enum.map(fn {citizen, _city_id} -> citizen["town_id"] end)
        end)

      occupied_slots_2 =
        Enum.flat_map(unemployed_preferred_locations_by_level, fn {_level, preferred_locations} ->
          preferred_locations.choices
          |> Enum.filter(fn {citizen, city_id} -> citizen["town_id"] != city_id end)
          |> Enum.map(fn {_citizen, city_id} -> city_id end)
        end)

      vacated_freq_2 = Enum.frequencies(vacated_slots_2)
      occupied_freq_2 = Enum.frequencies(occupied_slots_2)

      housing_slots_3 =
        housing_slots_2
        |> Map.merge(vacated_freq_2, fn _k, v1, v2 -> v1 + v2 end)
        |> Map.merge(occupied_freq_2, fn _k, v1, v2 -> v1 - v2 end)

      # NEW UNHOUSED CODE —————————————————————————————————————————————————————————————
      # ————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————
      # ————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————
      # ————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————
      # ————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————
      # ————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————

      unhoused_citizens_split =
        Map.new(5..0, fn x ->
          {x,
           Enum.split(
             Enum.filter(unhoused_citizens, fn cit -> cit["education"] == x end),
             Enum.sum(Map.values(unemployed_preferred_locations_by_level[x].slots))
           )}
        end)

      unhoused_preferred_locations_by_level =
        Map.new(5..0, fn level ->
          {level,
           Enum.reduce(
             elem(unhoused_citizens_split[level], 0),
             %{
               choices: [],
               slots: unemployed_preferred_locations_by_level[level].slots
             },
             fn citizen, acc ->
               chosen_city =
                 Enum.reduce(
                   acc.slots,
                   %{
                     chosen_id: citizen["town_id"],
                     top_score: -1
                   },
                   fn {city_id, count}, acc2 ->
                     score =
                       if count > 0 && city_id != citizen["town_id"] do
                         city_preference_scores[citizen["preferences"]][citizen["education"]][
                           city_id
                         ]
                       else
                         0
                       end

                     if score > acc2.top_score do
                       %{
                         chosen_id: city_id,
                         top_score: score
                       }
                     else
                       acc2
                     end
                   end
                 )

               updated_slots =
                 acc.slots
                 |> Map.update(chosen_city.chosen_id, 0, &(&1 - 1))

               %{
                 choices: [{citizen, chosen_city.chosen_id} | acc.choices],
                 slots: updated_slots
               }
             end
           )}
        end)

      # find a way to return these to origin city
      unhoused_split_2 =
        Enum.reduce(unhoused_citizens_split, [], fn {_k, v}, acc ->
          List.flatten([elem(v, 1) | acc])
        end)

      # ^ array of citizens who are still looking, that didn't make it into the level-specific comparisons

      # update the citizen's choice
      updated_citizens_by_id_6 =
        Enum.reduce(5..0, updated_citizens_by_id_5, fn x, acc ->
          if unhoused_preferred_locations_by_level[x].choices != [] do
            Enum.reduce(unhoused_preferred_locations_by_level[x].choices, acc, fn {citizen, chosen_city_id}, acc2 ->
              if citizen["town_id"] != chosen_city_id do
                acc2
                |> Map.update!(
                  chosen_city_id,
                  &[
                    citizen
                    |> Map.take(["education", "preferences", "age"])
                    | &1
                  ]
                )
              else
                acc2
                |> Map.update!(
                  chosen_city_id,
                  &[citizen |> Map.take(["education", "preferences", "age"]) | &1]
                )
              end
            end)
          else
            acc
          end
        end)

      vacated_slots_3 =
        Enum.flat_map(unhoused_preferred_locations_by_level, fn {_level, preferred_locations} ->
          preferred_locations.choices
          |> Enum.filter(fn {citizen, city_id} -> citizen["town_id"] != city_id end)
          |> Enum.map(fn {citizen, _city_id} -> citizen["town_id"] end)
        end)

      occupied_slots_3 =
        Enum.flat_map(unhoused_preferred_locations_by_level, fn {_level, preferred_locations} ->
          preferred_locations.choices
          |> Enum.filter(fn {citizen, city_id} -> citizen["town_id"] != city_id end)
          |> Enum.map(fn {_citizen, city_id} -> city_id end)
        end)

      vacated_freq_3 = Enum.frequencies(vacated_slots_3)
      occupied_freq_3 = Enum.frequencies(occupied_slots_3)

      housing_slots_4 =
        housing_slots_3
        |> Map.merge(vacated_freq_3, fn _k, v1, v2 -> v1 + v2 end)
        |> Map.merge(occupied_freq_3, fn _k, v1, v2 -> v1 - v2 end)

      # shape: [city_id, city_id, city_id]
      # subtract these from housing_slots
      # ok this is an array of… I think… housing to remove from those cities
      # this means a job was taken from second elem, and giving housing to the first one
      # yes
      # adjust housing_slots here

      # have to subtract from housing_slots and run again

      # ok gotta make an updated slots thingy

      # ——————————————————————————————————————————————————————————————————————————————————
      # ————————————————————————————————————————— ROUND 1.5: MOVE UNEMPLOYED CITIZENS
      # ——————————————————————————————————————————————————————————————————————————————————

      # ——————————————————————————————————————————————————————————————————————————————————
      # ————————————————————————————————————————— ROUND 2: MOVE CITIZENS ANYWHERE THERE IS HOUSING
      # ——————————————————————————————————————————————————————————————————————————————————

      slots_after_job_filtered = Enum.filter(housing_slots_4, fn {_k, v} -> v > 0 end) |> Enum.into(%{})

      housing_slots_left = Enum.sum(Map.values(housing_slots_4))

      unhoused_split_3 = unhoused_split_2 |> Enum.split(housing_slots_left)

      # SHAPE OF unhoused_locations.choices is an array of {citizen, city_id}
      unhoused_preferred_locations =
        Enum.reduce(
          elem(unhoused_split_3, 0),
          %{choices: [], slots: slots_after_job_filtered},
          fn citizen, acc ->
            current_city_score =
              city_preference_scores[citizen["preferences"]][citizen["education"]][
                citizen["town_id"]
              ]

            chosen_city =
              Enum.reduce(
                acc.slots,
                %{chosen_id: citizen["town_id"], top_score: current_city_score},
                fn {city_id, count}, acc2 ->
                  score =
                    if count > 0 do
                      city_preference_scores[citizen["preferences"]][citizen["education"]][
                        city_id
                      ]
                    else
                      0
                    end

                  if score > acc2.top_score && score do
                    %{
                      chosen_id: city_id,
                      top_score: score
                    }
                  else
                    acc2
                  end
                end
              )

            updated_slots =
              acc.slots
              |> Map.update(chosen_city.chosen_id, 0, &(&1 - 1))
              |> Map.update(citizen["town_id"], 0, &(&1 + 1))

            %{
              choices:
                if chosen_city.chosen_id == 0 do
                  acc.choices
                else
                  [{citizen, chosen_city.chosen_id} | acc.choices]
                end,
              slots: updated_slots
            }
          end
        )

      updated_citizens_by_id_7 =
        Enum.reduce(unhoused_preferred_locations.choices, updated_citizens_by_id_6, fn {citizen, chosen_city_id}, acc ->
          if citizen["town_id"] != chosen_city_id do
            acc |> Map.update!(chosen_city_id, &[citizen | &1])
          else
            acc
          end
        end)

      unhoused_deaths = elem(unhoused_split_3, 1) |> Enum.frequencies_by(& &1["town_id"])
      # ok cool
      # logs_deaths_housing: integer,

      # :logs_emigration_taxes,
      for_tax_logs =
        Enum.flat_map(preferred_locations_by_level, fn {_key, val} ->
          Enum.filter(val.choices, fn {citizen, chosen_id} -> citizen["town_id"] != chosen_id end)
        end)

      # tax_cities_chosen = Enum.group_by(for_tax_logs, &elem(&1, 1))
      tax_cities_left = Enum.group_by(for_tax_logs, &elem(&1, 0)["town_id"])

      tax_cities_left_by_edu =
        Enum.map(tax_cities_left, fn {city_id, array} ->
          {city_id, Enum.frequencies_by(array, &elem(&1, 0)["education"])}
        end)
        |> Map.new()

      # :logs_emigration_jobs,
      for_jobs_logs =
        Enum.flat_map(unemployed_preferred_locations_by_level, fn {_key, val} ->
          Enum.filter(val.choices, fn {citizen, chosen_id} -> citizen["town_id"] != chosen_id end)
        end)

      # job_cities_chosen = Enum.group_by(for_jobs_logs, &elem(&1, 1))
      job_cities_left = Enum.group_by(for_jobs_logs, &elem(&1, 0)["town_id"])

      job_cities_left_by_edu =
        Enum.map(job_cities_left, fn {city_id, array} ->
          {city_id, Enum.frequencies_by(array, &elem(&1, 0)["education"])}
        end)
        |> Map.new()

      # :logs_emigration_housing,
      for_unhoused_logs =
        Enum.flat_map(unhoused_preferred_locations_by_level, fn {_key, val} ->
          Enum.filter(val.choices, fn {citizen, chosen_id} -> citizen["town_id"] != chosen_id end)
        end)

      for_unhoused_logs_2 =
        Enum.filter(unhoused_preferred_locations.choices, fn {citizen, chosen_id} ->
          citizen["town_id"] != chosen_id
        end)

      # housing_cities_chosen = Enum.group_by(for_unhoused_logs, &elem(&1, 1))
      housing_cities_left = Enum.group_by(for_unhoused_logs, &elem(&1, 0)["town_id"])
      housing_cities_left_2 = Enum.group_by(for_unhoused_logs_2, &elem(&1, 0)["town_id"])

      merged_housing_cities_left = Map.merge(housing_cities_left, housing_cities_left_2, fn _k, v1, v2 -> v1 ++ v2 end)

      housing_cities_left_by_edu =
        Enum.map(merged_housing_cities_left, fn {city_id, array} ->
          {city_id, Enum.frequencies_by(array, &elem(&1, 0)["education"])}
        end)
        |> Map.new()

      # filter updated_citizens to remove jas_job and town_id before going in the DB

      # IO.inspect(updated_citizens_by_id_7)
      # ok this has all the ids I'd expect

      updated_citizens_by_id_7
      |> Enum.chunk_every(200)
      |> Enum.each(fn chunk ->
        Repo.checkout(
          # each comes with a city_id and a list of citizens
          fn ->
            Enum.each(chunk, fn {id, list} ->
              # each ID
              logs_emigration_taxes =
                if !is_nil(tax_cities_left_by_edu[id]) do
                  Map.merge(
                    CityHelpers.integerize_keys(slotted_cities_by_id[id].city.logs_emigration_taxes),
                    tax_cities_left_by_edu[id],
                    fn _k, v1, v2 -> v1 + v2 end
                  )
                else
                  slotted_cities_by_id[id].city.logs_emigration_taxes
                end

              logs_emigration_jobs =
                if !is_nil(job_cities_left_by_edu[id]) do
                  Map.merge(
                    CityHelpers.integerize_keys(slotted_cities_by_id[id].city.logs_emigration_jobs),
                    job_cities_left_by_edu[id],
                    fn _k, v1, v2 -> v1 + v2 end
                  )
                else
                  slotted_cities_by_id[id].city.logs_emigration_jobs
                end

              logs_emigration_housing =
                if !is_nil(housing_cities_left_by_edu[id]) do
                  Map.merge(
                    CityHelpers.integerize_keys(slotted_cities_by_id[id].city.logs_emigration_housing),
                    housing_cities_left_by_edu[id],
                    fn _k, v1, v2 -> v1 + v2 end
                  )
                else
                  slotted_cities_by_id[id].city.logs_emigration_housing
                end

              updated_edu_logs =
                Map.merge(
                  CityHelpers.integerize_keys(slotted_cities_by_id[id].city.logs_edu),
                  slotted_cities_by_id[id].city.educated_citizens,
                  fn _k, v1, v2 ->
                    v1 + v2
                  end
                )

              births_count =
                if slotted_cities_by_id[id].city.citizen_count > 20 do
                  max(slotted_cities_by_id[id].city.aggregate_births, 0)
                else
                  if :rand.uniform() > 0.5 do
                    1
                  else
                    0
                  end
                end

              updated_citizens =
                if births_count > 0 do
                  Enum.map(1..births_count, fn _citizen ->
                    %{
                      "age" => 0,
                      "town_id" => id,
                      "education" => 0,
                      "preferences" => :rand.uniform(11)
                    }
                  end) ++ list
                else
                  list
                end

              unhoused_deaths = if Map.has_key?(unhoused_deaths, id), do: unhoused_deaths[id], else: 0
              compress_blob = Citizens.compress_citizen_blob(updated_citizens, world.day)

              # IO.inspect(length(updated_citizens),
              #   label: slotted_cities_by_id[id].city.title <> " length after migrator "
              # )

              # if id == 2 do
              # log deaths
              # if births_count > 0,
              #   do: IO.inspect(births_count, label: slotted_cities_by_id[id].city.title <> " births_count")

              # if unhoused_deaths > 0,
              #   do: IO.inspect(unhoused_deaths, label: slotted_cities_by_id[id].city.title <> " unhoused_deaths")

              # if length(slotted_cities_by_id[id].city.polluted_citizens) > 0,
              #   do:
              #     IO.inspect(length(slotted_cities_by_id[id].city.polluted_citizens),
              #       label: slotted_cities_by_id[id].city.title <> " pollution_deaths"
              #     )

              # if slotted_cities_by_id[id].city.aggregate_deaths_by_age > 0,
              #   do:
              #     IO.inspect(slotted_cities_by_id[id].city.aggregate_deaths_by_age,
              #       label: slotted_cities_by_id[id].city.title <> " age_deaths"
              #     )

              # end

              from(t in Town,
                where: t.id == ^id,
                update: [
                  set: [
                    logs_emigration_taxes: ^logs_emigration_taxes,
                    logs_emigration_jobs: ^logs_emigration_jobs,
                    logs_emigration_housing: ^logs_emigration_housing,
                    logs_edu: ^updated_edu_logs,
                    citizen_count: ^length(updated_citizens),
                    # citizens_blob: ^updated_citizens,
                    citizens_compressed: ^compress_blob
                  ],
                  inc: [
                    logs_deaths_housing: ^unhoused_deaths,
                    logs_deaths_pollution: ^slotted_cities_by_id[id].city.aggregate_deaths_by_pollution,
                    logs_deaths_starvation: ^slotted_cities_by_id[id].city.aggregate_deaths_by_starvation,
                    logs_deaths_age: ^slotted_cities_by_id[id].city.aggregate_deaths_by_age,
                    logs_births: ^births_count
                  ]
                ]
              )
              |> Repo.update_all([])

              # ok wtf even this seems to work
            end)
          end,
          timeout: 6_000_000
        )
      end)
    end

    # SEND RESULTS TO CLIENTS
    # send val to liveView process that manages front-end; this basically sends to every client.
    MayorGameWeb.Endpoint.broadcast!(
      "cityPubSub",
      "pong",
      db_world
    )

    # profiling
    {:ok, datetime_post} = DateTime.now("Etc/UTC")

    IO.puts(
      (datetime_post |> DateTime.to_string()) <>
        " | Migration Tick | Time: " <>
        to_string(DateTime.diff(datetime_post, datetime_pre, :millisecond)) <> " ms"
    )

    # recurse, do it again
    Process.send_after(self(), :tax, 5000)

    # returns this to whatever calls ?
    {:noreply,
     %{
       world: db_world,
       buildables_map: buildables_map,
       in_dev: in_dev,
       migration_tick: migration_tick + 1
     }}
  end

  def nil_value_check(map, key) do
    if Map.has_key?(map, key), do: map[key], else: 0
  end

  def normalize_city(city, max_fun, spread_health, spread_pollution, max_sprawl, max_culture, max_crime) do
    %{
      city: city,
      jobs: city.vacancies_by_level,
      id: city.id,
      sprawl_normalized:
        zero_check(
          city |> TownStatistics.getResource(:sprawl) |> ResourceStatistics.getNetProduction(),
          max_sprawl
        ),
      pollution_normalized:
        zero_check(
          city |> TownStatistics.getResource(:pollution) |> ResourceStatistics.getNetProduction(),
          spread_pollution
        ),
      fun_normalized:
        zero_check(
          city |> TownStatistics.getResource(:fun) |> ResourceStatistics.getNetProduction(),
          max_fun
        ),
      health_normalized:
        zero_check(
          city |> TownStatistics.getResource(:health) |> ResourceStatistics.getNetProduction(),
          spread_health
        ),
      culture_normalized:
        zero_check(
          city |> TownStatistics.getResource(:culture) |> ResourceStatistics.getNetProduction(),
          max_culture
        ),
      crime_normalized:
        zero_check(
          city |> TownStatistics.getResource(:crime) |> ResourceStatistics.getNetProduction(),
          max_crime
        ),
      tax_rates: city.tax_rates
    }
  end

  def zero_check(check, divisor) do
    if check == 0 or divisor == 0, do: 0, else: check / divisor
  end

  def citizen_score(citizen_preferences, education_level, normalized_city) do
    # Clamp tax calculation preference between 0 & 1
    # Follows the following graph: https://www.desmos.com/calculator/69fewtjvma
    min(
      max(
        :math.pow(
          1 - normalized_city.tax_rates[to_string(education_level)],
          1.16 - citizen_preferences.tax_rates
        ),
        0
      ),
      1
    ) +
      (1 - normalized_city.pollution_normalized) * citizen_preferences.pollution +
      (1 - normalized_city.sprawl_normalized) * citizen_preferences.sprawl +
      normalized_city.fun_normalized * citizen_preferences.fun +
      normalized_city.health_normalized * citizen_preferences.health +
      normalized_city.culture_normalized * citizen_preferences.culture
  end
end
