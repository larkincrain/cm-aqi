defmodule CmAqiWeb.DashboardLive do
  @moduledoc """
  LiveView for the main AQI dashboard at "/".

  ## What is LiveView?

  Phoenix LiveView lets you build rich, interactive web pages in Elixir
  WITHOUT writing JavaScript. Here's how it works:

  1. **Initial page load**: The server renders HTML and sends it to the browser
     (just like a normal web page — great for SEO).
  2. **WebSocket connection**: After the page loads, LiveView establishes a
     persistent WebSocket connection between the browser and server.
  3. **Real-time updates**: When data changes on the server (e.g., new AQI readings),
     LiveView automatically computes the minimal DOM diff and pushes ONLY the
     changes to the browser. No full page reload needed!

  ## LiveView Lifecycle

  1. `mount/3` — Called when the page loads. Sets up initial state ("assigns").
  2. `handle_info/2` — Handles messages from PubSub (new AQI data).
  3. `handle_event/3` — Handles user interactions (button clicks, form submits).
  4. `render/1` — Generates the HTML template. Called automatically whenever
     assigns change.

  ## How This Dashboard Works

  - On mount, we fetch the latest readings from the database
  - We subscribe to the "aqi:updates" PubSub topic
  - When AqiPoller broadcasts new readings, `handle_info` fires
  - We update the assigns, LiveView re-renders only the changed parts
  - The browser shows the update instantly — no refresh needed!
  """

  use CmAqiWeb, :live_view

  alias CmAqi.AqiReadings
  alias CmAqi.AqiReadings.Calculator
  alias CmAqi.AqiPoller
  alias CmAqi.FirePoller

  # ============================================================================
  # LiveView Lifecycle Callbacks
  # ============================================================================

  @doc """
  Called when the LiveView is first mounted (page load).

  `mount/3` receives:
  - `params` — URL query parameters (e.g., `?station=123`)
  - `session` — The user's session data (from cookies)
  - `socket` — The LiveView socket, which holds all our state ("assigns")

  We use `assign/3` to put data into the socket's assigns. These assigns
  are available in the template as `@variable_name`.
  """
  @impl true
  def mount(_params, _session, socket) do
    # Subscribe to real-time updates if this is a connected client
    # (not during the initial static HTML render)
    if connected?(socket) do
      Phoenix.PubSub.subscribe(CmAqi.PubSub, "aqi:updates")
      Phoenix.PubSub.subscribe(CmAqi.PubSub, "fire:updates")
    end

    # Fetch current data from the database
    readings = AqiReadings.list_latest_readings()
    max_aqi = AqiReadings.max_current_aqi()
    avg_aqi = AqiReadings.average_current_aqi()

    # Group readings by station for the card layout
    stations = group_readings_by_station(readings)

    station_count = map_size(stations)

    socket =
      assign(socket,
        page_title: "Dashboard",
        meta_description:
          "Live Chiang Mai air quality dashboard. Current average AQI #{avg_aqi || "N/A"} from #{station_count} monitoring stations across northern Thailand.",
        canonical_path: "/",
        json_ld: %{
          "@context" => "https://schema.org",
          "@type" => "WebApplication",
          "name" => "CM AQI — Chiang Mai Air Quality",
          "url" => CmAqiWeb.Endpoint.url(),
          "description" =>
            "Real-time air quality monitoring for Chiang Mai, Thailand",
          "applicationCategory" => "UtilitiesApplication",
          "operatingSystem" => "Web",
          "offers" => %{
            "@type" => "Offer",
            "price" => "0",
            "priceCurrency" => "USD"
          }
        },
        stations: stations,
        max_aqi: max_aqi,
        avg_aqi: avg_aqi,
        avg_color: if(avg_aqi, do: Calculator.color_for_aqi(avg_aqi), else: "#808080"),
        avg_category: if(avg_aqi, do: Calculator.category_for_aqi(avg_aqi), else: nil),
        show_burn_warning: max_aqi != nil and max_aqi > 150,
        fire_count: length(FirePoller.list_fires()),
        last_updated: DateTime.utc_now()
      )

    # Push historical chart data for each station after the client connects.
    # push_event only works on connected sockets (not during static render).
    socket =
      if connected?(socket) do
        socket
        |> push_chart_data(stations)
        |> push_average_chart_data()
        |> push_map_data(stations)
        |> push_fire_data()
      else
        socket
      end

    {:ok, socket}
  end

  @doc """
  Handles real-time PubSub messages when new readings arrive.

  This is triggered by the AqiPoller GenServer broadcasting updates.
  When new data arrives, we update the assigns and LiveView automatically
  re-renders the changed parts of the page.
  """
  @impl true
  def handle_info({:readings_updated, _readings}, socket) do
    # Re-fetch all latest readings (simpler than merging partial updates)
    readings = AqiReadings.list_latest_readings()
    max_aqi = AqiReadings.max_current_aqi()
    stations = group_readings_by_station(readings)

    avg_aqi = AqiReadings.average_current_aqi()

    socket =
      assign(socket,
        stations: stations,
        max_aqi: max_aqi,
        avg_aqi: avg_aqi,
        avg_color: if(avg_aqi, do: Calculator.color_for_aqi(avg_aqi), else: "#808080"),
        avg_category: if(avg_aqi, do: Calculator.category_for_aqi(avg_aqi), else: nil),
        show_burn_warning: max_aqi != nil and max_aqi > 150,
        last_updated: DateTime.utc_now()
      )

    # Push updated chart and map data whenever new readings arrive
    socket =
      socket
      |> push_chart_data(stations)
      |> push_average_chart_data()
      |> push_map_data(stations)

    {:noreply, socket}
  end

  def handle_info({:fires_updated, fires}, socket) do
    socket =
      socket
      |> assign(fire_count: length(fires))
      |> push_fire_data()

    {:noreply, socket}
  end

  # ============================================================================
  # Template (render/1)
  # ============================================================================
  # In Phoenix 1.7+, you can write the template directly in the LiveView
  # module using the ~H sigil (HEEx = HTML + EEx + Elixir).

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <%!-- Page Header --%>
      <div class="text-center">
        <h1 class="text-3xl font-bold">Chiang Mai Air Quality</h1>
        <p class="text-base-content/60 mt-1">
          Real-time PM2.5 and PM10 monitoring stations
        </p>
        <p class="text-sm text-base-content/40 mt-1">
          Last updated: {format_datetime(@last_updated)}
        </p>
        <p :if={@fire_count > 0} class="text-sm mt-2">
          <span class="badge badge-warning gap-1">
            <span>🔥</span>
            {@fire_count} active fires detected in northern Thailand
          </span>
        </p>
      </div>

      <%!-- Burn Season Warning Banner --%>
      <%!--
        The `:if` attribute is a LiveView conditional.
        It only renders this element when the condition is true.
        This banner appears when any station exceeds AQI 150.
      --%>
      <div
        :if={@show_burn_warning}
        class="alert alert-warning shadow-lg"
        role="alert"
      >
        <svg
          xmlns="http://www.w3.org/2000/svg"
          class="stroke-current shrink-0 h-6 w-6"
          fill="none"
          viewBox="0 0 24 24"
        >
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"
          />
        </svg>
        <div>
          <h3 class="font-bold">Burn Season Warning</h3>
          <p class="text-sm">
            Air quality has exceeded unhealthy levels (AQI > 150).
            Consider wearing an N95 mask outdoors and limiting outdoor activity.
          </p>
        </div>
        <a href="/subscribe" class="btn btn-sm">Get Alerts</a>
      </div>

      <%!-- City Average Card --%>
      <div :if={@avg_aqi != nil} class="card bg-base-200 shadow-md overflow-hidden">
        <div class="h-2" style={"background-color: #{@avg_color}"}></div>
        <div class="card-body p-4">
          <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
            <div>
              <h2 class="card-title text-lg">Chiang Mai Average</h2>
              <div class="flex items-center gap-3 mt-1">
                <span class="text-5xl font-bold" style={"color: #{@avg_color}"}>
                  {@avg_aqi}
                </span>
                <div>
                  <span class="text-sm text-base-content/60">AQI</span>
                  <span
                    class="badge badge-lg text-white text-xs ml-2"
                    style={"background-color: #{@avg_color}"}
                  >
                    {@avg_category}
                  </span>
                </div>
              </div>
            </div>
            <div class="flex-1 min-w-0 h-32">
              <div
                id="chart-average"
                phx-hook="AqiChart"
                phx-update="ignore"
                data-station-id="average"
                class="h-full"
              >
                <canvas></canvas>
              </div>
            </div>
          </div>
        </div>
      </div>

      <%!-- Map --%>
      <div
        id="aqi-map"
        phx-hook="AqiMap"
        phx-update="ignore"
        class="rounded-lg overflow-hidden shadow-md h-72 sm:h-80"
      >
      </div>

      <%!-- Station Cards — Horizontal Scroll --%>
      <div :if={@stations == %{}} class="text-center py-12">
        <p class="text-lg text-base-content/60">
          No air quality data available yet.
        </p>
        <p class="text-sm text-base-content/40 mt-2">
          The poller will fetch data from AQICN shortly.
        </p>
      </div>

      <div class="flex gap-4 overflow-x-auto pb-2 -mx-2 px-2 snap-x snap-mandatory">
        <a
          :for={{station_id, station} <- @stations}
          href={"/sensors/#{station_id}"}
          class="card bg-base-200 shadow-md overflow-hidden flex-shrink-0 w-72 snap-start hover:bg-base-300 transition-colors"
        >
          <div class="h-2" style={"background-color: #{station.color}"}></div>

          <div class="card-body p-4">
            <h2 class="card-title text-sm leading-tight line-clamp-2">{station.name}</h2>

            <div class="flex items-end gap-2">
              <span class="text-3xl font-bold" style={"color: #{station.color}"}>
                {station.aqi_value || "—"}
              </span>
              <span class="text-xs text-base-content/60 mb-1">AQI</span>
            </div>
            <span
              class="badge text-white text-xs whitespace-nowrap self-start"
              style={"background-color: #{station.color}"}
            >
              {station.category || "No Data"}
            </span>

            <div class="grid grid-cols-2 gap-2 mt-1 text-xs">
              <div class="bg-base-300 rounded p-1.5">
                <span class="text-base-content/60">PM2.5</span>
                <span class="font-semibold ml-1">{format_value(station.pm25)}</span>
              </div>
              <div class="bg-base-300 rounded p-1.5">
                <span class="text-base-content/60">PM10</span>
                <span class="font-semibold ml-1">{format_value(station.pm10)}</span>
              </div>
            </div>

            <div
              id={"chart-#{station_id}"}
              phx-hook="AqiChart"
              phx-update="ignore"
              data-station-id={station_id}
              class="mt-2 h-24"
            >
              <canvas></canvas>
            </div>
          </div>
        </a>
      </div>
    </div>
    """
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # Pushes historical chart data to the browser for each station.
  # The JS hook (AqiChart) listens for "chart_data:<station_id>" events
  # and updates the Chart.js graph with the received labels and values.
  @spec push_chart_data(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  defp push_chart_data(socket, stations) do
    Enum.reduce(stations, socket, fn {station_id, _station}, sock ->
      readings = AqiReadings.list_readings_for_station(station_id)

      # Filter to PM2.5 readings for the chart (primary health metric)
      pm25_readings = Enum.filter(readings, &(&1.parameter == "pm25"))

      labels =
        Enum.map(pm25_readings, fn r ->
          r.measured_at
          |> DateTime.add(7 * 3600, :second)
          |> Calendar.strftime("%H:%M")
        end)

      values = Enum.map(pm25_readings, & &1.aqi_value)

      push_event(sock, "chart_data:#{station_id}", %{labels: labels, values: values})
    end)
  end

  # Pushes fire detection data to the Leaflet map hook.
  @spec push_fire_data(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp push_fire_data(socket) do
    fires =
      FirePoller.list_fires()
      |> Enum.map(fn f ->
        %{
          lat: f.lat,
          lng: f.lng,
          brightness: f.brightness,
          confidence: f.confidence,
          frp: f.frp,
          acq_date: f.acq_date,
          acq_time: f.acq_time
        }
      end)

    push_event(socket, "fire_data", %{fires: fires})
  end

  # Pushes historical average AQI data for the city-wide chart.
  # Reads from the pre-computed hourly_averages table (fast indexed read).
  @spec push_average_chart_data(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp push_average_chart_data(socket) do
    history = AqiReadings.list_average_readings_history()

    labels =
      Enum.map(history, fn avg ->
        avg.hour
        |> DateTime.add(7 * 3600, :second)
        |> Calendar.strftime("%H:%M")
      end)

    values = Enum.map(history, & &1.avg_aqi)

    push_event(socket, "chart_data:average", %{labels: labels, values: values})
  end

  # Pushes station marker data to the Leaflet map hook.
  # Merges active station readings with the full station list from the poller
  # so inactive stations appear greyed out on the map.
  @spec push_map_data(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  defp push_map_data(socket, active_stations) do
    # Get the full list of all stations (active + inactive) from the poller
    all_stations = AqiPoller.list_all_stations()

    # Build a lookup of active station data by uid
    active_lookup =
      active_stations
      |> Enum.into(%{}, fn {station_id, s} -> {station_id, s} end)

    markers =
      all_stations
      |> Enum.filter(fn s -> s.lat != nil and s.lng != nil end)
      |> Enum.map(fn s ->
        # Check if this station has active readings
        case Map.get(active_lookup, s.uid) do
          nil ->
            # Inactive station — grey marker
            %{
              id: s.uid,
              lat: s.lat,
              lng: s.lng,
              name: s.name,
              aqi: nil,
              color: "#808080",
              category: "Offline",
              active: false,
              within_50km: s.within_50km
            }

          active ->
            # Active station — colored by AQI
            %{
              id: s.uid,
              lat: s.lat,
              lng: s.lng,
              name: active.name,
              aqi: active.aqi_value,
              color: active.color,
              category: active.category,
              active: true,
              within_50km: s.within_50km
            }
        end
      end)

    push_event(socket, "map_data", %{markers: markers})
  end

  # Groups flat reading records into a map keyed by station_id.
  # Annotates each station with `within_50km` from the poller's station list.
  # Only includes stations within 50km for the dashboard card scroll.
  @spec group_readings_by_station(list()) :: map()
  defp group_readings_by_station(readings) do
    # Build lookup of within_50km flag from the poller's full station list
    inner_lookup =
      AqiPoller.list_all_stations()
      |> Enum.into(%{}, fn s -> {s.uid, s.within_50km} end)

    readings
    |> Enum.group_by(& &1.station_id)
    |> Enum.filter(fn {station_id, _} ->
      Map.get(inner_lookup, station_id, false)
    end)
    |> Enum.map(fn {station_id, station_readings} ->
      pm25 = Enum.find(station_readings, &(&1.parameter == "pm25"))
      pm10 = Enum.find(station_readings, &(&1.parameter == "pm10"))

      primary = pm25 || pm10
      aqi_value = if primary, do: primary.aqi_value, else: nil
      category = if primary, do: primary.category, else: nil
      color = if aqi_value, do: Calculator.color_for_aqi(aqi_value), else: "#808080"

      {station_id,
       %{
         name: if(primary, do: primary.station_name, else: "Unknown"),
         pm25: if(pm25, do: pm25.value, else: nil),
         pm10: if(pm10, do: pm10.value, else: nil),
         aqi_value: aqi_value,
         category: category,
         color: color,
         latitude: if(primary, do: primary.latitude, else: nil),
         longitude: if(primary, do: primary.longitude, else: nil),
         measured_at: if(primary, do: primary.measured_at, else: nil)
       }}
    end)
    |> Map.new()
  end

  # Formats a float value for display, or returns "—" if nil
  @spec format_value(float() | nil) :: String.t()
  defp format_value(nil), do: "—"
  defp format_value(value), do: :erlang.float_to_binary(value, decimals: 1)

  # Formats a DateTime for display in the Chiang Mai timezone (UTC+7)
  @spec format_datetime(DateTime.t() | nil) :: String.t()
  defp format_datetime(nil), do: "—"

  defp format_datetime(%DateTime{} = dt) do
    dt
    |> DateTime.add(7 * 3600, :second)
    |> Calendar.strftime("%b %d, %H:%M ICT")
  end
end
