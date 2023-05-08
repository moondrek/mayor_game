defmodule MayorGameWeb.CityCreationForm do
  # require Logger

  use Phoenix.LiveView, container: {:div, class: "liveview-container"}
  # don't need this because you get it in DashboardView?
  # use Phoenix.HTML

  alias MayorGame.City
  alias MayorGame.City.Town
  alias MayorGameWeb.DashboardView
  # alias MayorGame.Repo
  # alias Ecto.Changeset

  def render(assigns) do
    DashboardView.render("form.html", assigns)
  end

  # if user is logged in:
  def mount(_params, %{"current_user" => current_user}, socket) do
    {:ok,
     socket
     |> assign(current_user: current_user |> MayorGame.Repo.preload(:town))
     |> assign(regions: Town.regions())
     |> assign(climates: Town.climates())
     |> assign_new_city_changeset()}
  end

  # Create a city based on the payload that comes from the form (matched as `city_form`).
  # If its title is blank, build a title randomly
  # Finally, reload the current user's `cities` association, and re-assign it to the socket,
  # so the template will be re-rendered.
  def handle_event(
        "create_city",
        # grab "town" map from response and cast it into city_form
        %{"town" => city_form},
        # pattern match to pull these variables out of the socket
        %{
          assigns: %{
            # city_changeset: changeset,
            current_user: current_user
          }
        } = socket
      ) do
    city_form = Map.put(city_form, "user_id", current_user.id)

    # ok this needs to give attributes of user, title, region?
    case City.create_town(city_form) do
      # if city built successfully
      {:ok, _} ->
        IO.inspect('city_created')
        {:noreply, redirect(socket, to: "/city/" <> city_form["title"])}

      # {:error, err} ->
      #   Logger.error(inspect(err))

      {:error, %Ecto.Changeset{} = changeset} ->
        IO.puts("eyyy error")
        {:noreply, assign(socket, :city_changeset, changeset)}
    end
  end

  def handle_event(
        "validate",
        %{"town" => city_form},
        socket
      ) do
    # new changeset from the form changes
    new_changeset = City.change_town(%Town{}, Map.put(city_form, "user_id", socket.assigns[:current_user].id))

    # oh do I need to add the stuff from city_form to a changeset here?

    {:noreply, assign(socket, :city_changeset, new_changeset)}
  end

  # Build a changeset for the newly created city,
  # We'll use the changeset to drive a form to be displayed in the rendered template.
  defp assign_new_city_changeset(socket) do
    changeset =
      %Town{}
      |> Town.changeset(%{
        user_id: socket.assigns[:current_user].id
      })

    assign(socket, :city_changeset, changeset)
  end
end
