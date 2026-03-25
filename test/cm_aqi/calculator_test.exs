defmodule CmAqi.AqiReadings.CalculatorTest do
  @moduledoc """
  Tests for the AQI calculation formula.

  These tests verify that our implementation of the US EPA breakpoint formula
  correctly converts raw PM2.5 and PM10 concentrations to AQI values.

  ## Test Structure in Elixir

  - `use ExUnit.Case` — makes this module a test module
  - `describe` — groups related tests together (like `describe` in Jest/RSpec)
  - `test` — defines an individual test case
  - `assert` — verifies a condition is true (test fails if false)

  ## Running These Tests

      mix test test/cm_aqi/calculator_test.exs
  """

  # `async: true` means this test module can run in parallel with other test
  # modules. This is safe because these tests don't touch the database or
  # shared state — they're pure function tests.
  use ExUnit.Case, async: true

  alias CmAqi.AqiReadings.Calculator

  # ============================================================================
  # PM2.5 AQI Calculation Tests
  # ============================================================================

  describe "calculate_aqi/2 for PM2.5" do
    test "returns {0, \"Good\"} for 0.0 µg/m³" do
      {aqi, category} = Calculator.calculate_aqi("pm25", 0.0)
      assert aqi == 0
      assert category == "Good"
    end

    test "returns Good category for low concentrations" do
      {aqi, category} = Calculator.calculate_aqi("pm25", 5.0)
      assert aqi >= 0 and aqi <= 50
      assert category == "Good"
    end

    test "returns Moderate at the 9.1 breakpoint" do
      {aqi, category} = Calculator.calculate_aqi("pm25", 9.1)
      assert aqi == 51
      assert category == "Moderate"
    end

    test "returns Moderate for mid-range values" do
      {aqi, category} = Calculator.calculate_aqi("pm25", 20.0)
      assert aqi >= 51 and aqi <= 100
      assert category == "Moderate"
    end

    test "returns Unhealthy for Sensitive Groups at 35.5 breakpoint" do
      {aqi, category} = Calculator.calculate_aqi("pm25", 35.5)
      assert aqi == 101
      assert category == "Unhealthy for Sensitive Groups"
    end

    test "returns Unhealthy at the 55.5 breakpoint" do
      {aqi, category} = Calculator.calculate_aqi("pm25", 55.5)
      assert aqi == 151
      assert category == "Unhealthy"
    end

    test "returns Very Unhealthy at the 125.5 breakpoint" do
      {aqi, category} = Calculator.calculate_aqi("pm25", 125.5)
      assert aqi == 201
      assert category == "Very Unhealthy"
    end

    test "returns Hazardous at the 225.5 breakpoint" do
      {aqi, category} = Calculator.calculate_aqi("pm25", 225.5)
      assert aqi == 301
      assert category == "Hazardous"
    end

    test "returns upper Hazardous at the 325.5 breakpoint" do
      {aqi, category} = Calculator.calculate_aqi("pm25", 325.5)
      assert aqi == 401
      assert category == "Hazardous"
    end

    test "caps at 500 for extremely high concentrations" do
      {aqi, category} = Calculator.calculate_aqi("pm25", 600.0)
      assert aqi == 500
      assert category == "Hazardous"
    end

    test "handles negative concentrations gracefully" do
      {aqi, _category} = Calculator.calculate_aqi("pm25", -5.0)
      assert aqi == 0
    end

    test "handles the upper boundary of Good (9.0)" do
      {aqi, category} = Calculator.calculate_aqi("pm25", 9.0)
      assert aqi == 50
      assert category == "Good"
    end
  end

  # ============================================================================
  # PM10 AQI Calculation Tests
  # ============================================================================

  describe "calculate_aqi/2 for PM10" do
    test "returns Good for low concentrations" do
      {aqi, category} = Calculator.calculate_aqi("pm10", 25)
      assert aqi >= 0 and aqi <= 50
      assert category == "Good"
    end

    test "returns Moderate for mid-range" do
      {aqi, category} = Calculator.calculate_aqi("pm10", 100)
      assert aqi >= 51 and aqi <= 100
      assert category == "Moderate"
    end

    test "returns Unhealthy for Sensitive Groups at 155 boundary" do
      {aqi, category} = Calculator.calculate_aqi("pm10", 155)
      assert aqi == 101
      assert category == "Unhealthy for Sensitive Groups"
    end

    test "returns Unhealthy at 255 boundary" do
      {aqi, category} = Calculator.calculate_aqi("pm10", 255)
      assert aqi == 151
      assert category == "Unhealthy"
    end
  end

  # ============================================================================
  # Edge Cases and Unknown Parameters
  # ============================================================================

  describe "calculate_aqi/2 edge cases" do
    test "returns {0, \"Unknown\"} for unknown parameter" do
      assert Calculator.calculate_aqi("co2", 100.0) == {0, "Unknown"}
    end

    test "handles integer input" do
      {aqi, _category} = Calculator.calculate_aqi("pm25", 50)
      assert is_integer(aqi)
    end
  end

  # ============================================================================
  # Category Lookup Tests
  # ============================================================================

  describe "category_for_aqi/1" do
    test "returns correct categories for boundary values" do
      assert Calculator.category_for_aqi(0) == "Good"
      assert Calculator.category_for_aqi(50) == "Good"
      assert Calculator.category_for_aqi(51) == "Moderate"
      assert Calculator.category_for_aqi(100) == "Moderate"
      assert Calculator.category_for_aqi(101) == "Unhealthy for Sensitive Groups"
      assert Calculator.category_for_aqi(150) == "Unhealthy for Sensitive Groups"
      assert Calculator.category_for_aqi(151) == "Unhealthy"
      assert Calculator.category_for_aqi(200) == "Unhealthy"
      assert Calculator.category_for_aqi(201) == "Very Unhealthy"
      assert Calculator.category_for_aqi(300) == "Very Unhealthy"
      assert Calculator.category_for_aqi(301) == "Hazardous"
      assert Calculator.category_for_aqi(500) == "Hazardous"
    end
  end

  describe "color_for_aqi/1" do
    test "returns green for Good" do
      assert Calculator.color_for_aqi(25) == "#00e400"
    end

    test "returns red for Unhealthy" do
      assert Calculator.color_for_aqi(175) == "#ff0000"
    end

    test "returns maroon for Hazardous" do
      assert Calculator.color_for_aqi(400) == "#7e0023"
    end
  end

  describe "recommendation_for_aqi/1" do
    test "returns appropriate recommendation for each level" do
      rec = Calculator.recommendation_for_aqi(25)
      assert rec =~ "satisfactory"

      rec = Calculator.recommendation_for_aqi(175)
      assert rec =~ "mask"

      rec = Calculator.recommendation_for_aqi(400)
      assert rec =~ "Stay indoors"
    end
  end
end
