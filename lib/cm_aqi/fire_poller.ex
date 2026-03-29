defmodule CmAqi.FirePoller do
  @moduledoc """
  A GenServer that polls the NASA FIRMS API for active fire detections
  within a 1000 km radius of Chiang Mai.

  FIRMS (Fire Information for Resource Management System) provides
  near-real-time fire data from VIIRS satellites. We fetch fire hotspots
  every 30 minutes for a large bounding box covering Myanmar, Thailand,
  Laos, Vietnam, and southern China, and store them in GenServer state
  (no database needed since fire data is ephemeral — we only show the
  last 2 days).

  The data is broadcast via PubSub so the dashboard map can show fire
  locations alongside AQI sensors. The browser requests only fires
  visible in its current viewport.
  """

  use GenServer
  require Logger

  # Poll every 30 minutes
  @poll_interval :timer.minutes(30)

  # Retry after 5 minutes on failure
  @retry_interval :timer.minutes(5)

  # NASA FIRMS API base URL (area endpoint with bounding box)
  @firms_base_url "https://firms.modaps.eosdis.nasa.gov/api/area/csv"

  # VIIRS near-real-time data source
  @source "VIIRS_SNPP_NRT"

  # ~1000 km radius from Chiang Mai (18.7°N, 98.9°E)
  # Covers Myanmar, Thailand, Laos, Vietnam, and southern China
  # Format: west,south,east,north
  @coords "89.4,9.7,108.4,27.7"

  # Fetch last 2 days of fire data
  @day_range "2"

  # ============================================================================
  # Client API
  # ============================================================================

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the current list of fire detections.
  Each fire is a map with :lat, :lng, :brightness, :confidence, :frp, :acq_date, :acq_time.
  """
  @spec list_fires() :: [map()]
  def list_fires do
    GenServer.call(__MODULE__, :list_fires)
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    key = firms_map_key()

    if key == nil or key == "" do
      Logger.warning("FirePoller: FIRMS_MAP_KEY not configured — fire data disabled")
      {:ok, %{fires: [], error_count: 0}}
    else
      Logger.info("FirePoller starting — will poll NASA FIRMS every 30 minutes")
      schedule_poll(1_000)
      {:ok, %{fires: [], error_count: 0}}
    end
  end

  @impl true
  def handle_call(:list_fires, _from, state) do
    {:reply, state.fires, state}
  end

  @impl true
  def handle_info(:poll, state) do
    key = firms_map_key()

    if key == nil or key == "" do
      {:noreply, state}
    else
      case fetch_fires(key) do
        {:ok, fires} ->
          Logger.info("FirePoller: Fetched #{length(fires)} fire detections")
          broadcast_update(fires)
          schedule_poll(@poll_interval)
          {:noreply, %{state | fires: fires, error_count: 0}}

        {:error, reason} ->
          Logger.error("FirePoller: Failed to fetch fires — #{inspect(reason)}")
          schedule_poll(@retry_interval)
          {:noreply, %{state | error_count: state.error_count + 1}}
      end
    end
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp schedule_poll(delay) do
    Process.send_after(self(), :poll, delay)
  end

  defp fetch_fires(key) do
    url = "#{@firms_base_url}/#{key}/#{@source}/#{@coords}/#{@day_range}"

    # Use Req directly (not the HttpClient wrapper) because:
    # 1. We need to follow redirects (FIRMS does 307 from /latest/ to versioned URL)
    # 2. We need the raw text body, not JSON-decoded
    # 3. Large area may return a lot of data — generous timeout
    case Req.get(url, headers: [{"Accept", "text/csv"}], receive_timeout: 60_000) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        fires = parse_csv(body)
        Logger.info("FirePoller: Parsed #{length(fires)} fires from FIRMS API")
        {:ok, fires}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error(
          "FirePoller: FIRMS API returned status #{status}, " <>
            "body preview: #{inspect(String.slice(to_string(body), 0, 200))}"
        )

        {:error, "FIRMS API returned status #{status}"}

      {:error, reason} ->
        Logger.error("FirePoller: HTTP request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp parse_csv(csv_string) do
    lines = String.split(csv_string, "\n", trim: true)

    case lines do
      [_header | rows] ->
        Enum.flat_map(rows, fn row ->
          fields = String.split(row, ",")

          case fields do
            [lat, lng, brightness, _scan, _track, date, time, _sat, _inst, confidence, _ver, _bt5, frp | _rest] ->
              [
                %{
                  lat: parse_float(lat),
                  lng: parse_float(lng),
                  brightness: parse_float(brightness),
                  confidence: confidence,
                  frp: parse_float(frp),
                  acq_date: date,
                  acq_time: String.pad_leading(time, 4, "0")
                }
              ]

            _ ->
              []
          end
        end)
        |> Enum.filter(fn f -> f.lat != nil and f.lng != nil end)

      _ ->
        []
    end
  end

  defp parse_float(str) do
    case Float.parse(str) do
      {val, _} -> val
      :error -> nil
    end
  end

  defp firms_map_key do
    Application.get_env(:cm_aqi, :firms_map_key)
  end

  defp broadcast_update(fires) do
    Phoenix.PubSub.broadcast(
      CmAqi.PubSub,
      "fire:updates",
      {:fires_updated, fires}
    )
  end
end
