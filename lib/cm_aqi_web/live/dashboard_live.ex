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
    end

    # Fetch current data from the database
    readings = AqiReadings.list_latest_readings()
    max_aqi = AqiReadings.max_current_aqi()

    # Group readings by station for the card layout
    stations = group_readings_by_station(readings)

    socket =
      assign(socket,
        page_title: "Dashboard",
        stations: stations,
        max_aqi: max_aqi,
        show_burn_warning: max_aqi != nil and max_aqi > 150,
        last_updated: DateTime.utc_now()
      )

    # Push historical chart data for each station after the client connects.
    # push_event only works on connected sockets (not during static render).
    socket =
      if connected?(socket) do
        push_chart_data(socket, stations)
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

    socket =
      assign(socket,
        stations: stations,
        max_aqi: max_aqi,
        show_burn_warning: max_aqi != nil and max_aqi > 150,
        last_updated: DateTime.utc_now()
      )

    # Push updated chart data whenever new readings arrive
    socket = push_chart_data(socket, stations)

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

      <%!-- Station Cards Grid --%>
      <%!--
        `:for` is LiveView's loop syntax. It's equivalent to Enum.each.
        `{station_id, station}` destructures each map entry into key and value.
      --%>
      <div :if={@stations == %{}} class="text-center py-12">
        <p class="text-lg text-base-content/60">
          No air quality data available yet.
        </p>
        <p class="text-sm text-base-content/40 mt-2">
          The poller will fetch data from AQICN shortly.
        </p>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
        <div
          :for={{station_id, station} <- @stations}
          class="card bg-base-200 shadow-md overflow-hidden"
        >
          <%!-- Color-coded header bar based on AQI category --%>
          <div
            class="h-2"
            style={"background-color: #{station.color}"}
          >
          </div>

          <div class="card-body p-4">
            <%!-- Station Name --%>
            <h2 class="card-title text-base">{station.name}</h2>

            <%!-- AQI Value (large, prominent) --%>
            <div class="flex items-center justify-between">
              <div>
                <span
                  class="text-4xl font-bold"
                  style={"color: #{station.color}"}
                >
                  {station.aqi_value || "—"}
                </span>
                <span class="text-sm text-base-content/60 ml-2">AQI</span>
              </div>
              <%!-- Category Badge --%>
              <span
                class="badge badge-lg text-white text-xs"
                style={"background-color: #{station.color}"}
              >
                {station.category || "No Data"}
              </span>
            </div>

            <%!-- Raw Values --%>
            <div class="grid grid-cols-2 gap-2 mt-2 text-sm">
              <div class="bg-base-300 rounded p-2">
                <span class="text-base-content/60">PM2.5</span>
                <span class="font-semibold ml-1">
                  {format_value(station.pm25)} µg/m³
                </span>
              </div>
              <div class="bg-base-300 rounded p-2">
                <span class="text-base-content/60">PM10</span>
                <span class="font-semibold ml-1">
                  {format_value(station.pm10)} µg/m³
                </span>
              </div>
            </div>

            <%!-- Last Updated --%>
            <p class="text-xs text-base-content/40 mt-2">
              Updated: {format_datetime(station.measured_at)}
            </p>

            <%!-- Historical Chart --%>
            <%!--
              `phx-hook` connects this element to a JavaScript "Hook".
              Hooks let you run custom JS code when LiveView elements
              are mounted, updated, or destroyed. We use this to render
              a Chart.js chart.

              `phx-update="ignore"` tells LiveView not to touch this
              element's inner HTML — Chart.js manages it.

              The `data-*` attributes pass data from Elixir to JavaScript.
            --%>
            <div
              id={"chart-#{station_id}"}
              phx-hook="AqiChart"
              phx-update="ignore"
              data-station-id={station_id}
              class="mt-2 h-32"
            >
              <canvas></canvas>
            </div>
          </div>
        </div>
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

  # Groups flat reading records into a map keyed by station_id.
  # Each station entry has: name, pm25, pm10, aqi_value, category, color, measured_at
  @spec group_readings_by_station(list()) :: map()
  defp group_readings_by_station(readings) do
    readings
    |> Enum.group_by(& &1.station_id)
    |> Enum.map(fn {station_id, station_readings} ->
      # Find PM2.5 and PM10 readings for this station
      pm25 = Enum.find(station_readings, &(&1.parameter == "pm25"))
      pm10 = Enum.find(station_readings, &(&1.parameter == "pm10"))

      # Use PM2.5 as the primary AQI (it's the more health-relevant pollutant)
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
