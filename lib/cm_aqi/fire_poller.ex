defmodule CmAqi.FirePoller do
  @moduledoc """
  A GenServer that polls the NASA FIRMS API for active fire detections
  across Southeast Asia and China.

  FIRMS (Fire Information for Resource Management System) provides
  near-real-time fire data from VIIRS satellites. We fetch fire hotspots
  every 30 minutes for Myanmar, Thailand, Laos, Vietnam, and China,
  and store them in GenServer state (no database needed since fire data
  is ephemeral — we only show the last 2 days).

  The data is broadcast via PubSub so the dashboard map can show fire
  locations alongside AQI sensors.
  """

  use GenServer
  require Logger

  # Poll every 30 minutes
  @poll_interval :timer.minutes(30)

  # Retry after 5 minutes on failure
  @retry_interval :timer.minutes(5)

  # NASA FIRMS API base URL (country endpoint for exact borders)
  @firms_base_url "https://firms.modaps.eosdis.nasa.gov/api/country/csv"

  # VIIRS near-real-time data source
  @source "VIIRS_SNPP_NRT"

  # Countries to fetch fire data for (ISO 3166-1 alpha-3 codes)
  @countries [
    {"MMR", "Myanmar"},
    {"THA", "Thailand"},
    {"LAO", "Laos"},
    {"VNM", "Vietnam"},
    {"CHN", "China"}
  ]

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
    results =
      @countries
      |> Task.async_stream(
        fn {code, name} -> {name, fetch_country_fires(key, code)} end,
        max_concurrency: 3,
        timeout: 30_000
      )
      |> Enum.reduce({[], []}, fn
        {:ok, {name, {:ok, fires}}}, {all_fires, errors} ->
          Logger.info("FirePoller: Fetched #{length(fires)} fires for #{name}")
          {fires ++ all_fires, errors}

        {:ok, {name, {:error, reason}}}, {all_fires, errors} ->
          Logger.error("FirePoller: Failed to fetch fires for #{name} — #{inspect(reason)}")
          {all_fires, [name | errors]}

        {:exit, reason}, {all_fires, errors} ->
          Logger.error("FirePoller: Task exited — #{inspect(reason)}")
          {all_fires, ["unknown" | errors]}
      end)

    case results do
      {fires, []} ->
        {:ok, fires}

      {fires, errors} when fires != [] ->
        Logger.warning("FirePoller: Partial success — failed for: #{Enum.join(errors, ", ")}")
        {:ok, fires}

      {[], _errors} ->
        {:error, "All country fetches failed"}
    end
  end

  defp fetch_country_fires(key, country_code) do
    url = "#{@firms_base_url}/#{key}/#{@source}/#{country_code}/#{@day_range}"

    case Req.get(url, headers: [{"Accept", "text/csv"}], receive_timeout: 25_000) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        {:ok, parse_csv(body)}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error(
          "FirePoller: FIRMS API returned status #{status} for #{country_code}, " <>
            "body preview: #{inspect(String.slice(to_string(body), 0, 200))}"
        )

        {:error, "FIRMS API returned status #{status}"}

      {:error, reason} ->
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
