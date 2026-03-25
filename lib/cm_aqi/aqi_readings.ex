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
end
