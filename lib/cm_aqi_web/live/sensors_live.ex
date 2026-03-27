defmodule CmAqiWeb.SensorsLive do
  @moduledoc """
  LiveView for the Sensors page at "/sensors".

  Displays all Chiang Mai area sensors in a searchable, sortable vertical list.
  Updates in real-time when new readings arrive via PubSub.
  """

  use CmAqiWeb, :live_view

  alias CmAqi.AqiReadings
  alias CmAqi.AqiReadings.Calculator

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(CmAqi.PubSub, "aqi:updates")
    end

    readings = AqiReadings.list_latest_readings()
    stations = build_station_list(readings)

    {:ok,
     assign(socket,
       page_title: "Sensors",
       meta_description:
         "All #{length(stations)} air quality monitoring stations in the Chiang Mai area. Compare PM2.5 AQI readings across sensors in real time.",
       canonical_path: "/sensors",
       all_stations: stations,
       stations: stations,
       search: "",
       sort_by: "reading"
     )}
  end

  @impl true
  def handle_info({:readings_updated, _readings}, socket) do
    readings = AqiReadings.list_latest_readings()
    stations = build_station_list(readings)

    {:noreply,
     assign(socket,
       all_stations: stations,
       stations: filter_and_sort(stations, socket.assigns.search, socket.assigns.sort_by)
     )}
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    stations = filter_and_sort(socket.assigns.all_stations, search, socket.assigns.sort_by)
    {:noreply, assign(socket, search: search, stations: stations)}
  end

  @impl true
  def handle_event("sort", %{"sort" => sort_by}, socket) do
    stations = filter_and_sort(socket.assigns.all_stations, socket.assigns.search, sort_by)
    {:noreply, assign(socket, sort_by: sort_by, stations: stations)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="text-center">
        <h1 class="text-3xl font-bold">All Sensors</h1>
        <p class="text-base-content/60 mt-1">
          {length(@all_stations)} stations within 50km of Chiang Mai
        </p>
      </div>

      <%!-- Search and Sort Controls --%>
      <div class="flex flex-col sm:flex-row gap-3">
        <form phx-change="search" class="flex-1">
          <input
            type="text"
            name="search"
            value={@search}
            placeholder="Search by station name..."
            phx-debounce="200"
            class="input input-bordered w-full"
          />
        </form>
        <div class="flex gap-2">
          <button
            phx-click="sort"
            phx-value-sort="name"
            class={"btn btn-sm #{if @sort_by == "name", do: "btn-primary", else: "btn-ghost"}"}
          >
            Name
          </button>
          <button
            phx-click="sort"
            phx-value-sort="reading"
            class={"btn btn-sm #{if @sort_by == "reading", do: "btn-primary", else: "btn-ghost"}"}
          >
            AQI Reading
          </button>
        </div>
      </div>

      <%!-- Results count --%>
      <p :if={@search != ""} class="text-sm text-base-content/50">
        {length(@stations)} results
      </p>

      <%!-- Station List --%>
      <div class="space-y-2">
        <a
          :for={station <- @stations}
          href={"/sensors/#{station.station_id}"}
          class="flex items-center gap-3 p-3 bg-base-200 rounded-lg hover:bg-base-300 transition-colors"
        >
          <div
            class="w-3 h-3 rounded-full shrink-0"
            style={"background-color: #{station.color}"}
          >
          </div>

          <div class="flex-1 min-w-0">
            <p class="text-sm font-medium truncate">{station.name}</p>
            <p class="text-xs text-base-content/50">
              {station.category}
            </p>
          </div>

          <div class="text-right shrink-0">
            <span class="text-xl font-bold" style={"color: #{station.color}"}>
              {station.aqi_value || "—"}
            </span>
            <span class="text-xs text-base-content/50 ml-1">AQI</span>
          </div>
        </a>
      </div>

      <div :if={@stations == []} class="text-center py-8">
        <p class="text-base-content/50">No sensors match your search.</p>
      </div>
    </div>
    """
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # Builds a flat list of station maps from the latest readings.
  # Only includes stations within 50km of Chiang Mai.
  defp build_station_list(readings) do
    # Build lookup of within_50km flag from the poller
    inner_lookup =
      CmAqi.AqiPoller.list_all_stations()
      |> Enum.into(%{}, fn s -> {s.uid, s.within_50km} end)

    readings
    |> Enum.filter(fn r ->
      r.parameter == "pm25" and Map.get(inner_lookup, r.station_id, false)
    end)
    |> Enum.map(fn r ->
      aqi = r.aqi_value
      color = if aqi, do: Calculator.color_for_aqi(aqi), else: "#808080"

      %{
        station_id: r.station_id,
        name: r.station_name,
        aqi_value: aqi,
        category: if(aqi, do: Calculator.category_for_aqi(aqi), else: "No Data"),
        color: color
      }
    end)
    |> Enum.sort_by(& &1.aqi_value, :desc)
  end

  # Filters stations by search term and sorts by the chosen field.
  defp filter_and_sort(stations, search, sort_by) do
    stations
    |> filter_by_search(search)
    |> sort_stations(sort_by)
  end

  defp filter_by_search(stations, ""), do: stations

  defp filter_by_search(stations, search) do
    term = String.downcase(search)

    Enum.filter(stations, fn s ->
      String.downcase(s.name) |> String.contains?(term)
    end)
  end

  defp sort_stations(stations, "name") do
    Enum.sort_by(stations, &String.downcase(&1.name))
  end

  defp sort_stations(stations, _reading) do
    Enum.sort_by(stations, fn s -> s.aqi_value || 0 end, :desc)
  end
end
