defmodule CmAqi.AqiReadings do
  @moduledoc """
  The AqiReadings context — the public API for all air quality data operations.

  ## What is a Phoenix Context?

  In Phoenix, a "context" is a module that groups related functionality together
  and provides a clean public API. Think of it as a service layer or facade pattern.

  Instead of letting controllers/LiveViews talk directly to the database, they go
  through the context. This keeps your web layer thin and your business logic
  organized in one place.

  **Example flow:**
  LiveView → `AqiReadings.list_latest_readings()` → Ecto query → Database

  Rather than:
  LiveView → raw Ecto query → Database  (messy, hard to test)

  ## What This Context Does

  - Fetches and stores air quality readings from OpenAQ
  - Computes AQI values from raw PM2.5/PM10 concentrations
  - Provides queries for the dashboard (latest readings, historical data)
  - Handles "upsert" logic (insert new readings, update if duplicate)
  """

  # `import Ecto.Query` gives us query-building functions like `from`, `where`, `order_by`.
  # `alias` creates a shortcut so we can write `Reading` instead of `CmAqi.AqiReadings.Reading`.
  import Ecto.Query
  alias CmAqi.Repo
  alias CmAqi.AqiReadings.Reading
  alias CmAqi.AqiReadings.HourlyAverage
  alias CmAqi.AqiReadings.Calculator

  # ============================================================================
  # Querying Readings
  # ============================================================================

  @doc """
  Returns the most recent reading for each station and parameter.

  This is the main query powering the dashboard. It finds the latest PM2.5
  and PM10 reading for every monitoring station in Chiang Mai.

  ## How it works

  1. Groups readings by station_id and parameter
  2. Takes the maximum measured_at (most recent) for each group
  3. Joins back to get the full reading record

  ## Returns

  A list of `%Reading{}` structs, sorted by station name.
  """
  @spec list_latest_readings() :: [Reading.t()]
  def list_latest_readings do
    # This is an Ecto query using Elixir's query syntax.
    # `from r in Reading` creates a query starting from the aqi_readings table,
    # binding each row to the variable `r`.
    subquery =
      from r in Reading,
        # GROUP BY station_id, parameter — collapse rows into groups
        group_by: [r.station_id, r.parameter],
        # For each group, get the most recent timestamp
        select: %{
          station_id: r.station_id,
          parameter: r.parameter,
          max_measured_at: max(r.measured_at)
        }

    # Now join back to the original table to get the full row
    from(r in Reading,
      join: latest in subquery(subquery),
      on:
        r.station_id == latest.station_id and
          r.parameter == latest.parameter and
          r.measured_at == latest.max_measured_at,
      order_by: [asc: r.station_name, asc: r.parameter]
    )
    |> Repo.all()
  end

  @doc """
  Returns readings for a specific station over the last N hours.

  Used to render the historical chart on the dashboard.

  ## Parameters

  - `station_id` - The OpenAQ station identifier
  - `hours` - How many hours of history to fetch (default: 24)
  """
  @spec list_readings_for_station(String.t(), integer()) :: [Reading.t()]
  def list_readings_for_station(station_id, hours \\ 24) do
    # DateTime.utc_now() gets the current time in UTC.
    # DateTime.add/3 adds (or subtracts) seconds. -hours * 3600 goes back N hours.
    cutoff = DateTime.utc_now() |> DateTime.add(-hours * 3600, :second)

    from(r in Reading,
      where: r.station_id == ^station_id and r.measured_at >= ^cutoff,
      order_by: [asc: r.measured_at]
    )
    |> Repo.all()
  end

  @doc """
  Returns the previous reading for a station+parameter combo.

  Used by the AlertBroadcaster to detect threshold crossings — we compare
  the new reading's AQI to the previous one to see if it crossed a boundary.

  ## Parameters

  - `station_id` - The station identifier
  - `parameter` - "pm25" or "pm10"
  - `current_measured_at` - The timestamp of the current reading (we want the one before this)
  """
  @spec get_previous_reading(String.t(), String.t(), DateTime.t()) :: Reading.t() | nil
  def get_previous_reading(station_id, parameter, current_measured_at) do
    from(r in Reading,
      where:
        r.station_id == ^station_id and
          r.parameter == ^parameter and
          r.measured_at < ^current_measured_at,
      order_by: [desc: r.measured_at],
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  Returns the highest current AQI value across all stations.

  Used to determine whether to show the "Burn Season Warning" banner.
  """
  @spec max_current_aqi() :: integer() | nil
  def max_current_aqi do
    readings = list_latest_readings()

    case readings do
      [] ->
        nil

      readings ->
        readings
        |> Enum.map(& &1.aqi_value)
        |> Enum.filter(&(&1 != nil))
        |> Enum.max(fn -> nil end)
    end
  end

  @doc """
  Returns the average PM2.5 AQI value across stations within 50km of Chiang Mai.

  Only considers PM2.5 readings from stations in the inner radius.
  Stations outside 50km are shown on the map but excluded from the average.

  ## Returns

  An integer (rounded average AQI), or `nil` if no PM2.5 readings exist.
  """
  @spec average_current_aqi() :: integer() | nil
  def average_current_aqi do
    readings = list_latest_readings()

    aqi_values =
      readings
      |> Enum.filter(fn r ->
        r.parameter == "pm25" and r.aqi_value != nil and within_50km?(r.latitude, r.longitude)
      end)
      |> Enum.map(& &1.aqi_value)

    case aqi_values do
      [] -> nil
      values -> round(Enum.sum(values) / length(values))
    end
  end

  @doc """
  Returns pre-computed hourly city-wide average AQI values over the last N hours.

  Reads from the `hourly_averages` table which is populated by the poller
  each time new readings arrive. This is a simple indexed read — no aggregation.

  ## Returns

  A list of `%HourlyAverage{}` structs ordered chronologically.
  """
  @spec list_average_readings_history(integer()) :: [HourlyAverage.t()]
  def list_average_readings_history(hours \\ 24) do
    cutoff = DateTime.utc_now() |> DateTime.add(-hours * 3600, :second)

    from(a in HourlyAverage,
      where: a.hour >= ^cutoff,
      order_by: [asc: a.hour]
    )
    |> Repo.all()
  end

  @doc """
  Returns daily AQI summaries for the past 7 days.

  Each entry contains the date (in ICT / UTC+7), the day's average AQI,
  and a list of hourly averages for rendering a mini chart.

  ## Returns

  A list of maps: `%{date: Date.t(), avg_aqi: integer(), hourly: [%{hour: integer(), avg_aqi: integer()}]}`
  Ordered from oldest to newest.
  """
  @spec list_weekly_daily_averages() :: [map()]
  def list_weekly_daily_averages do
    # ICT is UTC+7. We shift the hour timestamps so days align to local time.
    now_ict = DateTime.utc_now() |> DateTime.add(7 * 3600, :second)
    today_ict = DateTime.to_date(now_ict)
    start_date = Date.add(today_ict, -6)
    # Convert back to UTC for the DB query: start of start_date in ICT = start_date midnight - 7h in UTC
    cutoff_utc = start_date |> Date.to_iso8601() |> then(&"#{&1}T00:00:00Z") |> DateTime.from_iso8601() |> elem(1) |> DateTime.add(-7 * 3600, :second)

    hourly_rows =
      from(a in HourlyAverage,
        where: a.hour >= ^cutoff_utc,
        order_by: [asc: a.hour]
      )
      |> Repo.all()

    # Group by ICT date
    hourly_rows
    |> Enum.group_by(fn row ->
      row.hour
      |> DateTime.add(7 * 3600, :second)
      |> DateTime.to_date()
    end)
    |> Enum.filter(fn {date, _} -> Date.compare(date, start_date) != :lt end)
    |> Enum.sort_by(fn {date, _} -> Date.to_iso8601(date) end)
    |> Enum.map(fn {date, rows} ->
      values = Enum.map(rows, & &1.avg_aqi) |> Enum.filter(&(&1 != nil))
      day_avg = if values == [], do: nil, else: round(Enum.sum(values) / length(values))

      hourly =
        rows
        |> Enum.sort_by(& &1.hour, DateTime)
        |> Enum.map(fn r ->
          hour_ict = DateTime.add(r.hour, 7 * 3600, :second)
          %{hour: hour_ict.hour, avg_aqi: r.avg_aqi}
        end)

      %{date: date, avg_aqi: day_avg, hourly: hourly}
    end)
  end

  @doc """
  Computes and upserts the city-wide hourly average AQI for the current hour.

  Called by the poller after new readings are stored. Averages all PM2.5
  readings from the current hour and writes the result to the `hourly_averages`
  table. Only counts stations that actually reported data.
  """
  @spec compute_and_store_hourly_average() :: {:ok, HourlyAverage.t()} | {:error, any()}
  def compute_and_store_hourly_average do
    now = DateTime.utc_now()
    hour = DateTime.truncate(now, :second) |> Map.merge(%{minute: 0, second: 0, microsecond: {0, 0}})

    # Get the latest PM2.5 reading for each station within 50km
    readings = list_latest_readings()

    aqi_values =
      readings
      |> Enum.filter(fn r ->
        r.parameter == "pm25" and r.aqi_value != nil and within_50km?(r.latitude, r.longitude)
      end)
      |> Enum.map(& &1.aqi_value)

    case aqi_values do
      [] ->
        {:error, :no_readings}

      values ->
        avg = round(Enum.sum(values) / length(values))

        %HourlyAverage{}
        |> HourlyAverage.changeset(%{
          hour: hour,
          avg_aqi: avg,
          station_count: length(values)
        })
        |> Repo.insert(
          on_conflict: {:replace, [:avg_aqi, :station_count, :updated_at]},
          conflict_target: [:hour],
          returning: true
        )
    end
  end

  @doc """
  Backfills the hourly_averages table from existing aqi_readings data.

  Computes the average PM2.5 AQI per hour from all historical readings
  and inserts them. Safe to run multiple times (upserts on conflict).
  """
  @spec backfill_hourly_averages() :: :ok
  def backfill_hourly_averages do
    Repo.query!("""
      INSERT INTO hourly_averages (hour, avg_aqi, station_count, inserted_at, updated_at)
      SELECT
        date_trunc('hour', measured_at) AT TIME ZONE 'UTC' AS hour,
        CAST(ROUND(AVG(aqi_value)) AS integer) AS avg_aqi,
        COUNT(DISTINCT station_id) AS station_count,
        NOW() AS inserted_at,
        NOW() AS updated_at
      FROM aqi_readings
      WHERE parameter = 'pm25' AND aqi_value IS NOT NULL
      GROUP BY date_trunc('hour', measured_at)
      ON CONFLICT (hour) DO UPDATE SET
        avg_aqi = EXCLUDED.avg_aqi,
        station_count = EXCLUDED.station_count,
        updated_at = NOW()
    """)

    :ok
  end

  # ============================================================================
  # Fetching Station Details
  # ============================================================================

  @waqi_base_url "https://api.waqi.info"

  @doc """
  Fetches detailed pollutant and weather data for a single station from the AQICN API.

  Returns individual AQI values for each pollutant (PM2.5, PM10, O3, NO2, SO2, CO)
  plus weather data (temperature, humidity, wind, pressure) when available.

  ## Returns

  `{:ok, details}` where details is a map with:
  - `:pollutants` — list of `%{key, label, value}` for air quality parameters
  - `:weather` — list of `%{key, label, value, unit}` for weather parameters
  - `:dominant_pollutant` — the dominant pollutant key (e.g., "pm25")
  - `:station_url` — link to the AQICN station page

  Or `{:error, reason}` on failure.
  """
  @spec fetch_station_details(String.t()) :: {:ok, map()} | {:error, any()}
  def fetch_station_details(station_id) do
    client = CmAqi.HttpClient.client()
    token = Application.get_env(:cm_aqi, :aqicn_api_token)

    url = "#{@waqi_base_url}/feed/@#{station_id}/?token=#{token}"

    case client.get(url, [{"Accept", "application/json"}]) do
      {:ok, %{status: 200, body: %{"status" => "ok", "data" => data}}} ->
        {:ok, parse_station_details(data)}

      {:ok, %{status: 200, body: %{"status" => "error", "data" => msg}}} ->
        {:error, msg}

      {:ok, %{status: status}} ->
        {:error, "AQICN API returned status #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @pollutant_labels %{
    "pm25" => "PM2.5",
    "pm10" => "PM10",
    "o3" => "Ozone (O₃)",
    "no2" => "NO₂",
    "so2" => "SO₂",
    "co" => "CO"
  }

  @weather_labels [
    {"t", "Temperature", "°C"},
    {"h", "Humidity", "%"},
    {"w", "Wind", "m/s"},
    {"p", "Pressure", "hPa"},
    {"d", "Dew Point", "°C"}
  ]

  defp parse_station_details(data) do
    iaqi = Map.get(data, "iaqi", %{})

    pollutants =
      @pollutant_labels
      |> Enum.map(fn {key, label} ->
        case get_in(iaqi, [key, "v"]) do
          nil -> nil
          val -> %{key: key, label: label, value: val}
        end
      end)
      |> Enum.reject(&is_nil/1)

    weather =
      @weather_labels
      |> Enum.map(fn {key, label, unit} ->
        case get_in(iaqi, [key, "v"]) do
          nil -> nil
          val -> %{key: key, label: label, value: val, unit: unit}
        end
      end)
      |> Enum.reject(&is_nil/1)

    station_url =
      case get_in(data, ["city", "url"]) do
        url when is_binary(url) -> url
        _ -> "https://aqicn.org/city/@#{Map.get(data, "idx", "")}"
      end

    %{
      pollutants: pollutants,
      weather: weather,
      dominant_pollutant: Map.get(data, "dominentpol"),
      station_url: station_url
    }
  end

  # ============================================================================
  # Creating / Upserting Readings
  # ============================================================================

  @doc """
  Inserts a new reading or updates it if a reading with the same
  station_id + parameter + measured_at already exists.

  This is called an "upsert" (update + insert). We need this because the OpenAQ
  API might return the same reading multiple times, and we don't want duplicates.

  ## How it works

  Ecto's `on_conflict` option maps to PostgreSQL's `ON CONFLICT ... DO UPDATE`.
  If inserting would violate the unique index, it updates the existing row instead.

  ## Parameters

  - `attrs` - A map of reading attributes from the OpenAQ API

  ## Returns

  `{:ok, %Reading{}}` on success, `{:error, %Ecto.Changeset{}}` on validation failure.
  """
  @spec upsert_reading(map()) :: {:ok, Reading.t()} | {:error, Ecto.Changeset.t()}
  def upsert_reading(attrs) do
    # First, calculate the AQI from the raw value
    attrs = maybe_calculate_aqi(attrs)

    %Reading{}
    |> Reading.changeset(attrs)
    |> Repo.insert(
      # on_conflict: tells PostgreSQL what to do when the unique index is violated
      on_conflict: {:replace, [:value, :aqi_value, :category, :updated_at]},
      # conflict_target: which unique index to check against
      conflict_target: [:station_id, :parameter, :measured_at],
      # returning: true means the query returns the final row (whether inserted or updated)
      returning: true
    )
  end

  @doc """
  Upserts multiple readings at once, calculating AQI for each.

  Returns a list of successfully upserted readings.
  """
  @spec upsert_readings(list(map())) :: [Reading.t()]
  def upsert_readings(readings_attrs) do
    readings_attrs
    # Enum.map transforms each element. `&upsert_reading/1` is a shorthand for
    # `fn attrs -> upsert_reading(attrs) end`. The `&` captures the function reference.
    |> Enum.map(&upsert_reading/1)
    # Enum.filter keeps only elements where the function returns true.
    # We keep only successful inserts and extract the reading from {:ok, reading}.
    |> Enum.filter(fn
      {:ok, _reading} -> true
      {:error, _changeset} -> false
    end)
    |> Enum.map(fn {:ok, reading} -> reading end)
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # Calculates AQI and category if not already present in the attributes.
  # If `aqi_value` and `category` are already set (e.g., from AQICN which provides
  # pre-computed AQI values), we skip the calculation and return attrs unchanged.
  @spec maybe_calculate_aqi(map()) :: map()
  defp maybe_calculate_aqi(%{"aqi_value" => aqi, "category" => cat} = attrs)
       when not is_nil(aqi) and not is_nil(cat) do
    # AQI already provided (e.g., from AQICN API) — no need to recalculate
    attrs
  end

  defp maybe_calculate_aqi(%{aqi_value: aqi, category: cat} = attrs)
       when not is_nil(aqi) and not is_nil(cat) do
    attrs
  end

  defp maybe_calculate_aqi(%{"parameter" => parameter, "value" => value} = attrs)
       when is_number(value) do
    {aqi_value, category} = Calculator.calculate_aqi(parameter, value)

    attrs
    |> Map.put("aqi_value", aqi_value)
    |> Map.put("category", category)
  end

  defp maybe_calculate_aqi(%{parameter: parameter, value: value} = attrs)
       when is_number(value) do
    {aqi_value, category} = Calculator.calculate_aqi(parameter, value)

    attrs
    |> Map.put(:aqi_value, aqi_value)
    |> Map.put(:category, category)
  end

  # If attrs don't have the expected keys, return unchanged
  defp maybe_calculate_aqi(attrs), do: attrs

  # Chiang Mai city center
  @cm_lat 18.79
  @cm_lng 98.98

  # Returns true if the given coordinates are within 50km of Chiang Mai center.
  @spec within_50km?(float() | nil, float() | nil) :: boolean()
  defp within_50km?(nil, _), do: false
  defp within_50km?(_, nil), do: false

  defp within_50km?(lat, lng) do
    haversine_km(@cm_lat, @cm_lng, lat, lng) <= 50
  end

  # Haversine formula — returns distance in km between two lat/lng points.
  @spec haversine_km(float(), float(), float(), float()) :: float()
  defp haversine_km(lat1, lng1, lat2, lng2) do
    r = 6371.0
    dlat = (lat2 - lat1) * :math.pi() / 180.0
    dlng = (lng2 - lng1) * :math.pi() / 180.0
    lat1_rad = lat1 * :math.pi() / 180.0
    lat2_rad = lat2 * :math.pi() / 180.0

    a =
      :math.sin(dlat / 2) * :math.sin(dlat / 2) +
        :math.cos(lat1_rad) * :math.cos(lat2_rad) *
          :math.sin(dlng / 2) * :math.sin(dlng / 2)

    c = 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
    r * c
  end
end
