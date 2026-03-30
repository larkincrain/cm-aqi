defmodule CmAqiWeb.MapLive do
  @moduledoc """
  Full-screen map LiveView at "/map".

  Shows all AQI sensors and fire detections on a full-viewport Leaflet map
  with heatmap overlay. Real-time updates via PubSub.
  """

  use CmAqiWeb, :live_view

  alias CmAqi.AqiReadings
  alias CmAqi.AqiReadings.Calculator
  alias CmAqi.AqiPoller
  alias CmAqi.FirePoller

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(CmAqi.PubSub, "aqi:updates")
      Phoenix.PubSub.subscribe(CmAqi.PubSub, "fire:updates")
    end

    readings = AqiReadings.list_latest_readings()
    stations = group_readings_by_station(readings)
    fire_count = length(FirePoller.list_fires())

    socket =
      assign(socket,
        page_title: "Map",
        meta_description:
          "Full-screen air quality and forest fire map for Chiang Mai and northern Thailand.",
        canonical_path: "/map",
        stations: stations,
        fire_count: fire_count
      )

    socket =
      if connected?(socket) do
        socket
        |> push_map_data(stations)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_info({:readings_updated, _readings}, socket) do
    readings = AqiReadings.list_latest_readings()
    stations = group_readings_by_station(readings)

    socket =
      socket
      |> assign(stations: stations)
      |> push_map_data(stations)

    {:noreply, socket}
  end

  def handle_info({:fires_updated, fires}, socket) do
    socket = assign(socket, fire_count: length(fires))

    socket =
      case socket.assigns[:fire_bounds] do
        nil -> socket
        bounds -> push_fire_data(socket, bounds)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("request_fires", %{"bounds" => bounds}, socket) do
    socket =
      socket
      |> assign(fire_bounds: bounds)
      |> push_fire_data(bounds)

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col -mx-6 -mt-8 sm:-mx-10 lg:-mx-16" style="height: calc(100vh - 4rem);">
      <%!-- Compact header bar --%>
      <div class="flex items-center justify-between px-4 py-2 bg-base-200">
        <a href="/" class="btn btn-ghost btn-sm gap-1">
          <.icon name="hero-arrow-left-mini" class="size-4" /> Dashboard
        </a>
        <span :if={@fire_count > 0} class="badge badge-warning badge-sm gap-1">
          <span>🔥</span> {@fire_count} fires
        </span>
      </div>
      <%!-- Full-height map --%>
      <div
        id="fullscreen-map"
        phx-hook="AqiMap"
        phx-update="ignore"
        class="flex-1"
      >
      </div>
    </div>
    """
  end

  # ============================================================================
  # Private Helpers — shared with DashboardLive
  # ============================================================================

  defp push_map_data(socket, stations_with_readings) do
    all_poller_stations = AqiPoller.list_all_stations()

    reading_lookup =
      stations_with_readings
      |> Enum.into(%{}, fn {station_id, s} -> {station_id, s} end)

    markers =
      all_poller_stations
      |> Enum.filter(fn s -> s.lat != nil and s.lng != nil end)
      |> Enum.map(fn s ->
        case Map.get(reading_lookup, s.uid) do
          nil ->
            %{
              id: s.uid, lat: s.lat, lng: s.lng, name: s.name,
              aqi: nil, color: "#808080", category: "Inactive",
              active: false
            }

          station ->
            %{
              id: s.uid, lat: s.lat, lng: s.lng, name: station.name,
              aqi: station.aqi_value, color: station.color, category: station.category,
              active: station.active
            }
        end
      end)

    push_event(socket, "map_data", %{markers: markers})
  end

  defp push_fire_data(socket, bounds) do
    south = bounds["south"]
    north = bounds["north"]
    west = bounds["west"]
    east = bounds["east"]

    fires =
      FirePoller.list_fires()
      |> Enum.filter(fn f ->
        f.lat >= south and f.lat <= north and f.lng >= west and f.lng <= east
      end)
      |> Enum.map(fn f ->
        %{
          la: Float.round(f.lat, 3),
          ln: Float.round(f.lng, 3),
          b: if(f.brightness, do: round(f.brightness)),
          c: f.confidence
        }
      end)

    push_event(socket, "fire_data", %{fires: fires})
  end

  defp group_readings_by_station(readings) do
    today_ict = today_in_ict()

    readings
    |> Enum.group_by(& &1.station_id)
    |> Enum.map(fn {station_id, station_readings} ->
      pm25 = Enum.find(station_readings, &(&1.parameter == "pm25"))
      primary = pm25 || Enum.find(station_readings, &(&1.parameter == "pm10"))
      aqi_value = if primary, do: primary.aqi_value, else: nil
      active = reading_from_today?(primary, today_ict)
      color = if active && aqi_value, do: Calculator.color_for_aqi(aqi_value), else: "#808080"

      {station_id,
       %{
         name: if(primary, do: primary.station_name, else: "Unknown"),
         aqi_value: aqi_value,
         category: if(active, do: (if primary, do: primary.category, else: nil), else: "Inactive"),
         color: color,
         active: active
       }}
    end)
    |> Map.new()
  end

  defp today_in_ict do
    DateTime.utc_now()
    |> DateTime.add(7 * 3600, :second)
    |> DateTime.to_date()
  end

  defp reading_from_today?(nil, _today), do: false

  defp reading_from_today?(reading, today_ict) do
    case reading.measured_at do
      nil ->
        false

      dt ->
        dt
        |> DateTime.add(7 * 3600, :second)
        |> DateTime.to_date()
        |> Date.compare(today_ict) == :eq
    end
  end
end
