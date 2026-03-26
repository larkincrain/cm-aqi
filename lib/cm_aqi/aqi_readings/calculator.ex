defmodule CmAqi.AqiReadings.Calculator do
  @moduledoc """
  Converts raw PM2.5 and PM10 concentrations into US EPA Air Quality Index (AQI) values.

  ## What is AQI?

  The Air Quality Index is a standardized scale from 0 to 500 that tells you how
  clean or polluted the air is. The US EPA defines breakpoint tables that map
  pollutant concentrations (like PM2.5 in µg/m³) to AQI values.

  ## How the Formula Works

  The EPA uses a piecewise linear function. For each pollutant, there are
  concentration "breakpoints" that define ranges. Within each range, we use
  linear interpolation to calculate the exact AQI value:

      AQI = ((aqi_high - aqi_low) / (conc_high - conc_low)) * (concentration - conc_low) + aqi_low

  ## AQI Categories

  | AQI Range | Category                        | Color   |
  |-----------|---------------------------------|---------|
  | 0-50      | Good                            | Green   |
  | 51-100    | Moderate                        | Yellow  |
  | 101-150   | Unhealthy for Sensitive Groups  | Orange  |
  | 151-200   | Unhealthy                       | Red     |
  | 201-300   | Very Unhealthy                  | Purple  |
  | 301-500   | Hazardous                       | Maroon  |

  ## Example

      iex> CmAqi.AqiReadings.Calculator.calculate_aqi("pm25", 35.5)
      {101, "Unhealthy for Sensitive Groups"}

  """

  # ============================================================================
  # Type Specifications
  # ============================================================================
  # @type and @spec are Elixir's way of documenting function signatures.
  # They don't enforce types at runtime (Elixir is dynamically typed), but they:
  # 1. Serve as documentation for developers
  # 2. Enable static analysis tools like Dialyzer to catch type errors
  # 3. Help your IDE provide better autocomplete

  @type category ::
          :good
          | :moderate
          | :unhealthy_sensitive
          | :unhealthy
          | :very_unhealthy
          | :hazardous

  @type aqi_result :: {non_neg_integer(), String.t()}

  # ============================================================================
  # PM2.5 Breakpoint Table (US EPA, 2024 revision)
  # ============================================================================
  # Each tuple is: {concentration_low, concentration_high, aqi_low, aqi_high}
  #
  # @doc tags before module attributes don't work — these are just constants.
  # The `@` symbol defines a "module attribute" — think of it as a constant
  # that's available anywhere in this module.

  @pm25_breakpoints [
    # Good: 0.0 - 9.0 µg/m³ → AQI 0-50
    {0.0, 9.0, 0, 50},
    # Moderate: 9.1 - 35.4 µg/m³ → AQI 51-100
    {9.1, 35.4, 51, 100},
    # Unhealthy for Sensitive Groups: 35.5 - 55.4 µg/m³ → AQI 101-150
    {35.5, 55.4, 101, 150},
    # Unhealthy: 55.5 - 125.4 µg/m³ → AQI 151-200
    {55.5, 125.4, 151, 200},
    # Very Unhealthy: 125.5 - 225.4 µg/m³ → AQI 201-300
    {125.5, 225.4, 201, 300},
    # Hazardous (lower): 225.5 - 325.4 µg/m³ → AQI 301-400
    {225.5, 325.4, 301, 400},
    # Hazardous (upper): 325.5 - 500.4 µg/m³ → AQI 401-500
    {325.5, 500.4, 401, 500}
  ]

  # ============================================================================
  # PM10 Breakpoint Table
  # ============================================================================

  @pm10_breakpoints [
    {0, 54, 0, 50},
    {55, 154, 51, 100},
    {155, 254, 101, 150},
    {255, 354, 151, 200},
    {355, 424, 201, 300},
    {425, 504, 301, 400},
    {505, 604, 401, 500}
  ]

  # ============================================================================
  # AQI Category Definitions
  # ============================================================================
  # Maps AQI ranges to human-readable category information.
  # Each entry contains: {label, color_hex, health_recommendation}

  @categories [
    {0, 50, "Good", "#198754", "Air quality is satisfactory. Enjoy outdoor activities!"},
    {51, 100, "Moderate", "#ffc107",
     "Air quality is acceptable. Unusually sensitive people should consider limiting prolonged outdoor exertion."},
    {101, 150, "Unhealthy for Sensitive Groups", "#fd7e14",
     "Members of sensitive groups may experience health effects. Consider wearing a mask outdoors."},
    {151, 200, "Unhealthy", "#dc3545",
     "Everyone may begin to experience health effects. Wear a mask outdoors and limit prolonged exertion."},
    {201, 300, "Very Unhealthy", "#6f42c1",
     "Health alert: everyone may experience more serious health effects. Avoid outdoor activity."},
    {301, 500, "Hazardous", "#842029",
     "Health emergency: the entire population is likely to be affected. Stay indoors with air purification."}
  ]

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Calculates the AQI value and category for a given pollutant concentration.

  ## Parameters

  - `parameter` - The pollutant type: `"pm25"` or `"pm10"`
  - `concentration` - The raw concentration value in µg/m³

  ## Returns

  A tuple of `{aqi_value, category_label}` where:
  - `aqi_value` is an integer from 0-500
  - `category_label` is a string like "Good" or "Unhealthy"

  ## Examples

      iex> CmAqi.AqiReadings.Calculator.calculate_aqi("pm25", 12.0)
      {51, "Moderate"}

      iex> CmAqi.AqiReadings.Calculator.calculate_aqi("pm10", 50)
      {46, "Good"}

  """
  @spec calculate_aqi(String.t(), number()) :: aqi_result()
  def calculate_aqi("pm25", concentration) when is_number(concentration) do
    # `when is_number(concentration)` is a "guard clause" — it's a condition
    # that must be true for this function clause to match. Guards run before
    # the function body and only allow simple expressions.
    do_calculate(concentration, @pm25_breakpoints)
  end

  def calculate_aqi("pm10", concentration) when is_number(concentration) do
    do_calculate(concentration, @pm10_breakpoints)
  end

  # This is a "catch-all" clause. In Elixir, functions can have multiple clauses
  # (like overloads). Elixir tries each clause from top to bottom until one matches.
  # If none of the above match (wrong parameter name), we return a safe default.
  def calculate_aqi(_parameter, _concentration) do
    {0, "Unknown"}
  end

  @doc """
  Returns the category label for a given AQI value.

  ## Examples

      iex> CmAqi.AqiReadings.Calculator.category_for_aqi(75)
      "Moderate"

      iex> CmAqi.AqiReadings.Calculator.category_for_aqi(160)
      "Unhealthy"

  """
  @spec category_for_aqi(integer()) :: String.t()
  def category_for_aqi(aqi_value) when is_integer(aqi_value) do
    # Enum.find/2 iterates through the list and returns the first element
    # where the function returns a truthy value. It's like Array.find() in JS.
    case Enum.find(@categories, fn {low, high, _label, _color, _rec} ->
           aqi_value >= low and aqi_value <= high
         end) do
      {_low, _high, label, _color, _rec} -> label
      # nil means no match found (shouldn't happen with valid AQI values)
      nil -> "Unknown"
    end
  end

  @doc """
  Returns the hex color code for a given AQI value.

  Used to color-code the dashboard cards and LINE notification headers.

  ## Examples

      iex> CmAqi.AqiReadings.Calculator.color_for_aqi(42)
      "#00e400"

  """
  @spec color_for_aqi(integer()) :: String.t()
  def color_for_aqi(aqi_value) when is_integer(aqi_value) do
    case Enum.find(@categories, fn {low, high, _label, _color, _rec} ->
           aqi_value >= low and aqi_value <= high
         end) do
      {_low, _high, _label, color, _rec} -> color
      nil -> "#808080"
    end
  end

  @doc """
  Returns the health recommendation for a given AQI value.

  ## Examples

      iex> CmAqi.AqiReadings.Calculator.recommendation_for_aqi(155)
      "Everyone may begin to experience health effects. Wear a mask outdoors and limit prolonged exertion."

  """
  @spec recommendation_for_aqi(integer()) :: String.t()
  def recommendation_for_aqi(aqi_value) when is_integer(aqi_value) do
    case Enum.find(@categories, fn {low, high, _label, _color, _rec} ->
           aqi_value >= low and aqi_value <= high
         end) do
      {_low, _high, _label, _color, recommendation} -> recommendation
      nil -> "No data available."
    end
  end

  @doc """
  Returns all category information for a given AQI value.

  ## Returns

  A map with keys: `:label`, `:color`, `:recommendation`
  """
  @spec category_info(integer()) :: map()
  def category_info(aqi_value) when is_integer(aqi_value) do
    case Enum.find(@categories, fn {low, high, _label, _color, _rec} ->
           aqi_value >= low and aqi_value <= high
         end) do
      {_low, _high, label, color, recommendation} ->
        %{label: label, color: color, recommendation: recommendation}

      nil ->
        %{label: "Unknown", color: "#808080", recommendation: "No data available."}
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================
  # Functions defined with `defp` (note the `p` for "private") can only be
  # called from within this module. This is good practice for internal helpers.

  # The actual AQI calculation using the EPA breakpoint formula.
  @spec do_calculate(number(), list()) :: aqi_result()
  defp do_calculate(concentration, breakpoints) when concentration < 0 do
    # Negative concentrations don't make sense — treat as zero
    do_calculate(0, breakpoints)
  end

  defp do_calculate(concentration, breakpoints) do
    # Truncate to 1 decimal place, as per EPA guidelines for PM2.5
    # Float.round/2 rounds a float to N decimal places
    truncated = Float.round(concentration / 1.0, 1)

    # Find which breakpoint range this concentration falls into
    case find_breakpoint(truncated, breakpoints) do
      {:ok, {conc_low, conc_high, aqi_low, aqi_high}} ->
        # Apply the EPA linear interpolation formula:
        # AQI = ((AQI_high - AQI_low) / (Conc_high - Conc_low)) * (Conc - Conc_low) + AQI_low
        aqi =
          ((aqi_high - aqi_low) / (conc_high - conc_low) * (truncated - conc_low) + aqi_low)
          |> round()
          |> trunc()

        # `|>` is the "pipe operator" — Elixir's most iconic feature!
        # It takes the result of the left side and passes it as the first
        # argument to the function on the right side. So `x |> round() |> trunc()`
        # is the same as `trunc(round(x))`, but reads left-to-right.

        {aqi, category_for_aqi(aqi)}

      :error ->
        # Concentration exceeds the breakpoint table — cap at 500 (Hazardous)
        {500, "Hazardous"}
    end
  end

  # Searches the breakpoint table for the range containing this concentration.
  # Returns {:ok, breakpoint_tuple} or :error if not found.
  @spec find_breakpoint(float(), list()) :: {:ok, tuple()} | :error
  defp find_breakpoint(concentration, breakpoints) do
    # Enum.find returns the first element where the function returns truthy
    result =
      Enum.find(breakpoints, fn {conc_low, conc_high, _aqi_low, _aqi_high} ->
        concentration >= conc_low and concentration <= conc_high
      end)

    # Pattern matching: if result is nil (not found), return :error
    # Otherwise wrap it in {:ok, result}. This {:ok, value} / :error pattern
    # is very common in Elixir — it's how we handle success/failure without exceptions.
    case result do
      nil -> :error
      breakpoint -> {:ok, breakpoint}
    end
  end
end
