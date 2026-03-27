defmodule CmAqi.AqiPoller do
  @moduledoc """
  A GenServer that periodically polls the AQICN (waqi.info) API for air quality data.

  ## What is a GenServer?

  GenServer stands for "Generic Server" — it's one of the most important concepts
  in Elixir/OTP (Open Telecom Platform). A GenServer is a process that:

  1. **Runs in the background** — it's a long-lived process that starts when your
     app starts and keeps running
  2. **Maintains state** — it can hold data in memory between calls
  3. **Handles messages** — other parts of your app can send it messages
  4. **Is supervised** — if it crashes, the supervisor automatically restarts it

  Think of it like a background worker thread, but much more resilient.

  ## What This GenServer Does

  Every 10 minutes, it:
  1. Searches the AQICN API for all Chiang Mai monitoring stations
  2. Fetches detailed readings (PM2.5, PM10, AQI) for each active station
  3. Upserts the readings into the database (avoiding duplicates)
  4. Broadcasts the updated readings to PubSub so the LiveView dashboard updates
  5. If the API call fails, it logs the error and retries in 2 minutes

  ## AQICN API

  We use the World Air Quality Index (WAQI) JSON API:
  - Search endpoint: `https://api.waqi.info/search/?keyword=chiang+mai`
  - Station feed: `https://api.waqi.info/feed/@{station_uid}/`
  - Authentication: `?token=YOUR_TOKEN` query parameter
  - Docs: https://aqicn.org/json-api/doc/

  Unlike OpenAQ, AQICN already provides computed AQI values and individual
  pollutant AQI readings (PM2.5, PM10, O3, etc.) directly in the response.

  ## GenServer Lifecycle

      start_link/1 → init/1 → handle_info(:poll) → (waits 10 min) → handle_info(:poll) → ...
                                    ↓
                              If error: handle_info(:retry) after 2 min

  """

  use GenServer

  # `require Logger` makes the Logger macros available (Logger.info, Logger.error, etc.)
  require Logger

  alias CmAqi.AqiReadings

  # ============================================================================
  # Configuration Constants
  # ============================================================================
  # Module attributes prefixed with @ are compile-time constants.

  # Poll every 10 minutes (in milliseconds)
  @poll_interval :timer.minutes(10)

  # Retry after 2 minutes if the API call fails
  @retry_interval :timer.minutes(2)

  # The AQICN / WAQI API base URL
  @waqi_base_url "https://api.waqi.info"

  # ============================================================================
  # Client API (Public Functions)
  # ============================================================================
  # These functions are called by OTHER processes to interact with this GenServer.
  # They run in the CALLER's process, not in the GenServer process.

  @doc """
  Starts the AqiPoller GenServer and links it to the calling process.

  `start_link` is the conventional name for the function that starts a GenServer.
  It's called by the supervisor when the app boots. The `name: __MODULE__` option
  registers this process with a name so we can find it later without its PID.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Manually triggers a poll. Useful for testing and debugging.

  `GenServer.cast/2` sends an asynchronous message — it doesn't wait for a reply.
  This is called a "cast" (fire-and-forget) vs "call" (request-reply).
  """
  @spec poll_now() :: :ok
  def poll_now do
    GenServer.cast(__MODULE__, :poll_now)
  end

  @doc """
  Returns the full list of Chiang Mai stations discovered by the last search,
  including inactive ones. Each entry is a map with :uid, :name, :lat, :lng, :active.

  Used by the dashboard to show all stations on the map (inactive ones greyed out).
  """
  @spec list_all_stations() :: [map()]
  def list_all_stations do
    GenServer.call(__MODULE__, :list_all_stations)
  end

  # ============================================================================
  # Server Callbacks (GenServer Behaviour)
  # ============================================================================
  # These functions run INSIDE the GenServer process. They handle messages
  # sent to this process. The `@impl true` annotation tells the compiler
  # these implement the GenServer behaviour callbacks.

  @doc """
  Called once when the GenServer starts. Sets up initial state and schedules
  the first poll.

  ## The State

  A GenServer's state can be any Elixir term. Here we use a map with:
  - `:last_poll_at` - When we last successfully polled (nil initially)
  - `:poll_count` - How many times we've polled (for monitoring)
  - `:error_count` - How many consecutive errors (resets on success)

  ## Scheduling

  `Process.send_after/3` schedules a message to be sent to this process
  after a delay. We send :poll to ourselves after 1 second (initial delay)
  so the GenServer finishes starting quickly.
  """
  @impl true
  def init(_opts) do
    Logger.info("AqiPoller starting — will poll AQICN every 10 minutes")

    # Schedule the first poll shortly after startup
    # We use a short delay (1 second) so the app can finish booting first
    schedule_poll(1_000)

    # Return {:ok, state} to tell the supervisor we started successfully.
    # The state map is our GenServer's persistent state.
    {:ok,
     %{
       last_poll_at: nil,
       poll_count: 0,
       error_count: 0,
       all_stations: []
     }}
  end

  @doc """
  Handles the periodic :poll message.

  `handle_info/2` is called when the GenServer receives a message that wasn't
  sent via `call` or `cast`. Our `Process.send_after` messages arrive here.
  """
  @impl true
  def handle_info(:poll, state) do
    Logger.info("AqiPoller: Starting poll ##{state.poll_count + 1}")

    case fetch_and_store_readings() do
      {:ok, readings, all_stations} ->
        Logger.info("AqiPoller: Successfully stored #{length(readings)} readings from #{length(all_stations)} stations")

        # Compute and store the hourly average for the chart
        AqiReadings.compute_and_store_hourly_average()

        # Broadcast to PubSub so LiveView dashboards update in real-time.
        # Any process subscribed to "aqi:updates" will receive this message.
        broadcast_update(readings)

        # Schedule the next regular poll
        schedule_poll(@poll_interval)

        # Update state: reset error count, record success, store full station list
        {:noreply,
         %{
           state
           | last_poll_at: DateTime.utc_now(),
             poll_count: state.poll_count + 1,
             error_count: 0,
             all_stations: all_stations
         }}

      {:error, reason} ->
        Logger.error("AqiPoller: Failed to fetch readings — #{inspect(reason)}")

        # Schedule a retry sooner than the normal interval
        schedule_poll(@retry_interval)

        {:noreply, %{state | error_count: state.error_count + 1}}
    end
  end

  @impl true
  def handle_call(:list_all_stations, _from, state) do
    {:reply, state.all_stations, state}
  end

  @doc """
  Handles the manual :poll_now cast.
  """
  @impl true
  def handle_cast(:poll_now, state) do
    # Reuse the same logic as the scheduled poll by sending ourselves the :poll message
    send(self(), :poll)
    {:noreply, state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  # Schedules a :poll message to be sent to this process after `delay` milliseconds.
  @spec schedule_poll(non_neg_integer()) :: reference()
  defp schedule_poll(delay) do
    Process.send_after(self(), :poll, delay)
  end

  # Fetches readings from AQICN and stores them in the database.
  #
  # The flow is:
  # 1. Search for all Chiang Mai stations using the /search/ endpoint
  # 2. For each active station, fetch detailed data using the /feed/@uid/ endpoint
  # 3. Parse PM2.5 and PM10 readings from the response
  # 4. Upsert all readings into the database
  #
  # Returns {:ok, readings} or {:error, reason}.
  @spec fetch_and_store_readings() :: {:ok, list(), list()} | {:error, any()}
  defp fetch_and_store_readings do
    client = CmAqi.HttpClient.client()
    token = aqicn_token()

    if token == nil or token == "" do
      {:error,
       "AQICN_API_TOKEN not configured. Get one at https://aqicn.org/data-platform/token/"}
    else
      # We wrap the entire fetch+store in a try/rescue because database connection
      # errors (e.g., Postgres is down) raise exceptions instead of returning errors.
      # Without this, a DB outage would crash the GenServer in a tight loop.
      try do
        with {:ok, all_stations, readings_attrs} <- search_stations(client, token) do
          stored = AqiReadings.upsert_readings(readings_attrs)
          {:ok, stored, all_stations}
        end
      rescue
        e in DBConnection.ConnectionError ->
          {:error, "Database connection failed: #{Exception.message(e)}"}

        e ->
          {:error, "Unexpected error: #{Exception.message(e)}"}
      end
    end
  end

  # Step 1: Find all stations within ~50km of Chiang Mai using the map bounds API.
  #
  # The /v2/map/bounds endpoint returns all stations within a lat/lng bounding box.
  # This gives us far more stations than the keyword search (55+ vs 21).
  # The bounding box is approximately 50km around Chiang Mai city center (18.79, 98.98).
  #
  # Returns {all_stations_for_map, active_raw_stations_for_feed_fetch}.
  @spec search_stations(module(), String.t()) ::
          {:ok, list(map()), list(map())} | {:error, any()}
  defp search_stations(client, token) do
    # ~50km bounding box around Chiang Mai (18.79, 98.98)
    # 0.3 degrees latitude ≈ 33km, using 0.3 gives ~60km total span
    url =
      "#{@waqi_base_url}/v2/map/bounds?latlng=18.49,98.68,19.09,99.28&networks=all&token=#{token}"

    case client.get(url, [{"Accept", "application/json"}]) do
      {:ok, %{status: 200, body: %{"status" => "ok", "data" => data}}} when is_list(data) ->
        # Parse all stations for the map display
        all_stations = Enum.map(data, &parse_bounds_station/1)

        # Build reading attributes directly from bounds data for active stations.
        # The bounds API provides the overall AQI, which during burn season is
        # always driven by PM2.5. This avoids 55+ individual /feed/ API calls.
        readings_attrs =
          data
          |> Enum.filter(fn station ->
            aqi = Map.get(station, "aqi")
            is_number(aqi) or (is_binary(aqi) and aqi != "-")
          end)
          |> Enum.map(&bounds_station_to_reading/1)

        Logger.info(
          "AqiPoller: Found #{length(all_stations)} stations in 50km radius, " <>
            "#{length(readings_attrs)} with active readings"
        )

        {:ok, all_stations, readings_attrs}

      {:ok, %{status: status, body: body}} ->
        Logger.error("AqiPoller: Bounds API returned status #{status}: #{inspect(body)}")
        {:error, "AQICN bounds API returned status #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Parses a station from the map bounds response into a clean map for the dashboard.
  @spec parse_bounds_station(map()) :: map()
  defp parse_bounds_station(station) do
    uid = Map.get(station, "uid")
    aqi_raw = Map.get(station, "aqi")
    name = get_in(station, ["station", "name"]) || "Station #{uid}"
    lat = Map.get(station, "lat")
    lon = Map.get(station, "lon")

    active =
      cond do
        is_number(aqi_raw) and aqi_raw > 0 -> true
        is_binary(aqi_raw) and aqi_raw != "-" -> true
        true -> false
      end

    %{
      uid: to_string(uid),
      name: name,
      lat: lat,
      lng: lon,
      active: active
    }
  end

  # Converts a bounds API station into a reading attributes map for upserting.
  # The bounds API provides the overall AQI value directly, so we don't need
  # to call /feed/ for each station individually.
  @spec bounds_station_to_reading(map()) :: map()
  defp bounds_station_to_reading(station) do
    uid = Map.get(station, "uid")
    aqi_raw = Map.get(station, "aqi")
    name = get_in(station, ["station", "name"]) || "Station #{uid}"
    time_str = get_in(station, ["station", "time"])
    lat = Map.get(station, "lat")
    lon = Map.get(station, "lon")

    aqi_int =
      cond do
        is_integer(aqi_raw) -> aqi_raw
        is_float(aqi_raw) -> round(aqi_raw)
        is_binary(aqi_raw) -> String.to_integer(aqi_raw)
        true -> nil
      end

    measured_at =
      case time_str && DateTime.from_iso8601(time_str) do
        {:ok, dt, _offset} -> DateTime.truncate(dt, :second)
        _ -> DateTime.utc_now() |> DateTime.truncate(:second)
      end

    %{
      "station_id" => to_string(uid),
      "station_name" => name,
      "parameter" => "pm25",
      "value" => if(aqi_int, do: aqi_int / 1.0, else: 0.0),
      "aqi_value" => aqi_int,
      "category" => if(aqi_int, do: CmAqi.AqiReadings.Calculator.category_for_aqi(aqi_int)),
      "unit" => "AQI",
      "latitude" => lat,
      "longitude" => lon,
      "measured_at" => measured_at
    }
  end

  # Returns the AQICN API token from application config.
  # Register for a free token at https://aqicn.org/data-platform/token/
  @spec aqicn_token() :: String.t() | nil
  defp aqicn_token do
    Application.get_env(:cm_aqi, :aqicn_api_token)
  end

  # Broadcasts updated readings to PubSub so LiveViews can update in real-time.
  @spec broadcast_update(list()) :: :ok
  defp broadcast_update(readings) do
    Phoenix.PubSub.broadcast(
      CmAqi.PubSub,
      "aqi:updates",
      {:readings_updated, readings}
    )
  end
end
