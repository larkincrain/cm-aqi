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
       error_count: 0
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
      {:ok, readings} ->
        Logger.info("AqiPoller: Successfully stored #{length(readings)} readings")

        # Broadcast to PubSub so LiveView dashboards update in real-time.
        # Any process subscribed to "aqi:updates" will receive this message.
        broadcast_update(readings)

        # Schedule the next regular poll
        schedule_poll(@poll_interval)

        # Update state: reset error count, record success
        {:noreply,
         %{
           state
           | last_poll_at: DateTime.utc_now(),
             poll_count: state.poll_count + 1,
             error_count: 0
         }}

      {:error, reason} ->
        Logger.error("AqiPoller: Failed to fetch readings — #{inspect(reason)}")

        # Schedule a retry sooner than the normal interval
        schedule_poll(@retry_interval)

        {:noreply, %{state | error_count: state.error_count + 1}}
    end
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
  @spec fetch_and_store_readings() :: {:ok, list()} | {:error, any()}
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
        with {:ok, stations} <- search_stations(client, token),
             {:ok, readings} <- fetch_station_details(client, token, stations) do
          stored = AqiReadings.upsert_readings(readings)
          {:ok, stored}
        end
      rescue
        e in DBConnection.ConnectionError ->
          {:error, "Database connection failed: #{Exception.message(e)}"}

        e ->
          {:error, "Unexpected error: #{Exception.message(e)}"}
      end
    end
  end

  # Step 1: Search for all Chiang Mai monitoring stations.
  #
  # The AQICN search endpoint returns a list of stations matching a keyword.
  # Each station has a uid, current AQI, name, and coordinates.
  # We filter out stations with no current data (aqi == "-").
  @spec search_stations(module(), String.t()) :: {:ok, list(map())} | {:error, any()}
  defp search_stations(client, token) do
    url = "#{@waqi_base_url}/search/?keyword=chiang+mai&token=#{token}"

    case client.get(url, [{"Accept", "application/json"}]) do
      {:ok, %{status: 200, body: %{"status" => "ok", "data" => data}}} when is_list(data) ->
        # Filter out stations with no current data (aqi == "-" means offline)
        active_stations =
          Enum.filter(data, fn station ->
            aqi = get_in(station, ["aqi"])
            aqi != "-" and aqi != nil
          end)

        Logger.info("AqiPoller: Found #{length(active_stations)} active Chiang Mai stations")
        {:ok, active_stations}

      {:ok, %{status: 200, body: %{"status" => "error", "data" => msg}}} ->
        {:error, "AQICN API error: #{msg}"}

      {:ok, %{status: status}} ->
        {:error, "AQICN returned status #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Step 2: Fetch detailed data for each station.
  #
  # The /feed/@uid/ endpoint returns the full station data including individual
  # pollutant readings (PM2.5, PM10, etc.) in the `iaqi` field, plus the
  # overall AQI, timestamps, and coordinates.
  @spec fetch_station_details(module(), String.t(), list(map())) ::
          {:ok, list(map())} | {:error, any()}
  defp fetch_station_details(client, token, stations) do
    readings =
      stations
      |> Enum.flat_map(fn station ->
        uid = get_in(station, ["uid"])
        fetch_single_station(client, token, uid)
      end)

    {:ok, readings}
  end

  # Fetches detailed data for a single station by its AQICN uid.
  # Returns a list of reading maps (one for PM2.5, one for PM10 if available).
  @spec fetch_single_station(module(), String.t(), integer() | String.t()) :: list(map())
  defp fetch_single_station(client, token, uid) do
    url = "#{@waqi_base_url}/feed/@#{uid}/?token=#{token}"

    case client.get(url, [{"Accept", "application/json"}]) do
      {:ok, %{status: 200, body: %{"status" => "ok", "data" => data}}} when is_map(data) ->
        parse_station_data(data)

      {:ok, response} ->
        Logger.warning("AqiPoller: Unexpected response for station #{uid}: #{inspect(response)}")
        []

      {:error, reason} ->
        Logger.warning("AqiPoller: Failed to fetch station #{uid}: #{inspect(reason)}")
        []
    end
  end

  # Parses the AQICN station feed response into reading attribute maps.
  #
  # AQICN response structure:
  # %{
  #   "aqi" => 127,              ← overall AQI (based on dominant pollutant)
  #   "idx" => 5775,             ← station unique ID
  #   "dominentpol" => "pm25",   ← which pollutant drives the overall AQI
  #   "city" => %{
  #     "name" => "Chiang Mai",
  #     "geo" => [18.787, 98.993]  ← [latitude, longitude]
  #   },
  #   "iaqi" => %{               ← individual pollutant AQI values
  #     "pm25" => %{"v" => 127},
  #     "pm10" => %{"v" => 82},
  #     ...
  #   },
  #   "time" => %{
  #     "iso" => "2024-03-15T09:00:00+07:00"
  #   }
  # }
  @spec parse_station_data(map()) :: list(map())
  defp parse_station_data(data) do
    station_id = to_string(Map.get(data, "idx", ""))
    station_name = get_in(data, ["city", "name"]) || "Unknown Station"

    # Extract coordinates from the [lat, lng] array
    geo = get_in(data, ["city", "geo"]) || []
    latitude = Enum.at(geo, 0)
    longitude = Enum.at(geo, 1)

    # Parse the measurement timestamp
    measured_at = parse_timestamp(data)

    # Extract individual pollutant readings from the "iaqi" map.
    # AQICN provides AQI values (not raw µg/m³) for each pollutant.
    iaqi = Map.get(data, "iaqi", %{})

    # Build readings for PM2.5 and PM10 (the pollutants we track)
    ["pm25", "pm10"]
    |> Enum.filter(fn param -> Map.has_key?(iaqi, param) end)
    |> Enum.map(fn param ->
      # The "v" field contains the AQI value for this specific pollutant
      aqi_value = get_in(iaqi, [param, "v"])
      aqi_int = if is_number(aqi_value), do: round(aqi_value), else: nil

      %{
        "station_id" => station_id,
        "station_name" => station_name,
        "parameter" => param,
        # AQICN gives us AQI values, not raw concentrations.
        # We store the AQI value as both `value` and `aqi_value`.
        "value" => if(is_number(aqi_value), do: aqi_value / 1.0, else: 0.0),
        "aqi_value" => aqi_int,
        "category" => if(aqi_int, do: CmAqi.AqiReadings.Calculator.category_for_aqi(aqi_int)),
        "unit" => "AQI",
        "latitude" => latitude,
        "longitude" => longitude,
        "measured_at" => measured_at
      }
    end)
  end

  # Parses the timestamp from the AQICN response.
  # The API provides an ISO 8601 timestamp with timezone offset.
  @spec parse_timestamp(map()) :: DateTime.t()
  defp parse_timestamp(data) do
    iso_string = get_in(data, ["time", "iso"])

    case iso_string && DateTime.from_iso8601(iso_string) do
      {:ok, dt, _offset} -> DateTime.truncate(dt, :second)
      _ -> DateTime.utc_now() |> DateTime.truncate(:second)
    end
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
