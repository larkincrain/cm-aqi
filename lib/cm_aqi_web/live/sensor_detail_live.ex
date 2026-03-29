defmodule CmAqiWeb.SensorDetailLive do
  @moduledoc """
  LiveView for the sensor detail page at "/sensors/:station_id".

  Shows a single sensor's current reading, location on a Leaflet map,
  and a historical AQI chart over the last 24 hours.
  """

  use CmAqiWeb, :live_view

  alias CmAqi.AqiReadings
  alias CmAqi.AqiReadings.Calculator

  @impl true
  def mount(%{"station_id" => station_id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(CmAqi.PubSub, "aqi:updates")
    end

    socket = load_station_data(socket, station_id)

    {:ok, socket}
  end

  @impl true
  def handle_info({:readings_updated, _readings}, socket) do
    {:noreply, load_station_data(socket, socket.assigns.station_id)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <%!-- Back link --%>
      <a href="/sensors" class="btn btn-ghost btn-sm gap-1">
        <.icon name="hero-arrow-left-mini" class="size-4" /> All Sensors
      </a>

      <%!-- Station header --%>
      <div class="card bg-base-200 shadow-md overflow-hidden">
        <div class="h-2" style={"background-color: #{@color}"}></div>
        <div class="card-body p-5">
          <h1 class="text-xl font-bold leading-tight">{@station_name}</h1>

          <div class="flex items-end gap-3 mt-2">
            <span class="text-5xl font-bold" style={"color: #{@color}"}>
              {@aqi_value || "—"}
            </span>
            <div class="mb-1">
              <span class="text-sm text-base-content/60">AQI</span>
              <span
                class="badge text-white text-xs ml-2 whitespace-nowrap"
                style={"background-color: #{@color}"}
              >
                {@category}
              </span>
            </div>
          </div>

          <p :if={@recommendation} class="text-sm text-base-content/70 mt-2">
            {@recommendation}
          </p>

          <p class="text-xs text-base-content/40 mt-2">
            Last updated: {format_datetime(@measured_at)}
          </p>

          <a
            :if={@station_url}
            href={@station_url}
            target="_blank"
            rel="noopener noreferrer"
            class="btn btn-outline btn-sm mt-3 gap-1"
          >
            View on AQICN <.icon name="hero-arrow-top-right-on-square-mini" class="size-4" />
          </a>
        </div>
      </div>

      <%!-- Pollutant readings --%>
      <div :if={@pollutants != []} class="card bg-base-200 shadow-md">
        <div class="card-body p-5">
          <h2 class="card-title text-base">Pollutants</h2>
          <div class="grid grid-cols-2 sm:grid-cols-3 gap-3 mt-2">
            <div :for={p <- @pollutants} class="bg-base-300 rounded-lg p-3">
              <p class="text-xs text-base-content/50">{p.label}</p>
              <p class="text-2xl font-bold mt-1" style={pollutant_color(p)}>
                {format_value(p.value)}
              </p>
              <p class="text-xs text-base-content/40">
                {if p.key == @dominant_pollutant, do: "Dominant", else: "AQI"}
              </p>
            </div>
          </div>
        </div>
      </div>

      <%!-- Weather conditions --%>
      <div :if={@weather != []} class="card bg-base-200 shadow-md">
        <div class="card-body p-5">
          <h2 class="card-title text-base">Weather Conditions</h2>
          <div class="grid grid-cols-2 sm:grid-cols-3 gap-3 mt-2">
            <div :for={w <- @weather} class="bg-base-300 rounded-lg p-3">
              <p class="text-xs text-base-content/50">{w.label}</p>
              <p class="text-xl font-bold mt-1">
                {format_value(w.value)}<span class="text-sm font-normal text-base-content/60">{w.unit}</span>
              </p>
            </div>
          </div>
        </div>
      </div>

      <%!-- Map --%>
      <div
        id="sensor-map"
        phx-hook="SensorMap"
        phx-update="ignore"
        data-lat={@latitude}
        data-lng={@longitude}
        data-name={@station_name}
        data-aqi={@aqi_value}
        data-color={@color}
        class="rounded-lg overflow-hidden shadow-md h-64"
      >
      </div>

      <%!-- Historical chart --%>
      <div class="card bg-base-200 shadow-md">
        <div class="card-body p-5">
          <h2 class="card-title text-base">24-Hour History</h2>
          <div
            id={"chart-#{@station_id}"}
            phx-hook="AqiChart"
            phx-update="ignore"
            data-station-id={@station_id}
            class="h-48"
          >
            <canvas></canvas>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp load_station_data(socket, station_id) do
    readings = AqiReadings.list_readings_for_station(station_id)
    pm25_readings = Enum.filter(readings, &(&1.parameter == "pm25"))

    latest = List.last(pm25_readings)

    aqi_value = if latest, do: latest.aqi_value
    color = if aqi_value, do: Calculator.color_for_aqi(aqi_value), else: "#808080"
    info = if aqi_value, do: Calculator.category_info(aqi_value)

    station_name = if(latest, do: latest.station_name, else: "Sensor #{station_id}")
    category = if(info, do: info.label, else: "No Data")
    lat = if(latest, do: latest.latitude)
    lng = if(latest, do: latest.longitude)

    # Fetch detailed pollutant and weather data from AQICN feed API
    {pollutants, weather, dominant_pollutant, station_url} =
      case AqiReadings.fetch_station_details(station_id) do
        {:ok, details} ->
          {details.pollutants, details.weather, details.dominant_pollutant, details.station_url}

        {:error, _reason} ->
          {[], [], nil, nil}
      end

    json_ld =
      if aqi_value && lat && lng do
        %{
          "@context" => "https://schema.org",
          "@type" => "Place",
          "name" => station_name,
          "geo" => %{
            "@type" => "GeoCoordinates",
            "latitude" => lat,
            "longitude" => lng
          },
          "additionalProperty" => %{
            "@type" => "PropertyValue",
            "name" => "Air Quality Index (AQI)",
            "value" => aqi_value,
            "unitText" => "US EPA AQI"
          }
        }
      end

    socket =
      assign(socket,
        station_id: station_id,
        page_title: station_name,
        meta_description:
          "Current AQI #{aqi_value || "N/A"} (#{category}) at #{station_name}, Chiang Mai. Live PM2.5 air quality data with 24-hour history chart.",
        canonical_path: "/sensors/#{station_id}",
        json_ld: json_ld,
        station_name: station_name,
        aqi_value: aqi_value,
        category: category,
        color: color,
        recommendation: if(info, do: info.recommendation),
        latitude: lat,
        longitude: lng,
        measured_at: if(latest, do: latest.measured_at),
        pollutants: pollutants,
        weather: weather,
        dominant_pollutant: dominant_pollutant,
        station_url: station_url
      )

    if connected?(socket) do
      labels =
        Enum.map(pm25_readings, fn r ->
          r.measured_at
          |> DateTime.add(7 * 3600, :second)
          |> Calendar.strftime("%H:%M")
        end)

      values = Enum.map(pm25_readings, & &1.aqi_value)

      push_event(socket, "chart_data:#{station_id}", %{labels: labels, values: values})
    else
      socket
    end
  end

  defp format_datetime(nil), do: "—"

  defp format_datetime(%DateTime{} = dt) do
    dt
    |> DateTime.add(7 * 3600, :second)
    |> Calendar.strftime("%b %d, %H:%M ICT")
  end

  defp format_value(val) when is_float(val), do: :erlang.float_to_binary(val, decimals: 1)
  defp format_value(val), do: to_string(val)

  defp pollutant_color(%{value: val}) when is_number(val) and val > 0 do
    aqi = round(val)
    "color: #{Calculator.color_for_aqi(min(aqi, 500))}"
  end

  defp pollutant_color(_), do: ""
end
