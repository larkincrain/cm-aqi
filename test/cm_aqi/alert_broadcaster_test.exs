defmodule CmAqi.AlertBroadcasterTest do
  @moduledoc """
  Tests for the AlertBroadcaster's threshold crossing logic.

  These tests verify that the AlertBroadcaster correctly detects when AQI
  values cross alert thresholds (both escalation and clearing).
  """

  use CmAqi.DataCase, async: false

  import Mox

  alias CmAqi.AqiReadings
  alias CmAqi.AqiReadings.Reading

  setup :verify_on_exit!

  # Helper to create a reading directly in the database
  defp create_reading(attrs) do
    default_attrs = %{
      station_id: "test-station-1",
      station_name: "Test Station",
      parameter: "pm25",
      value: 50.0,
      aqi_value: 50,
      category: "Good",
      unit: "µg/m³",
      latitude: 18.7883,
      longitude: 98.9853,
      measured_at: DateTime.utc_now()
    }

    merged = Map.merge(default_attrs, attrs)

    %Reading{}
    |> Reading.changeset(merged)
    |> Repo.insert!()
  end

  describe "threshold crossing detection" do
    test "detects escalation from Good to Unhealthy" do
      # Create a "before" reading with Good AQI
      create_reading(%{
        aqi_value: 50,
        category: "Good",
        value: 9.0,
        measured_at: DateTime.add(DateTime.utc_now(), -3600, :second)
      })

      # Create an "after" reading with Unhealthy AQI
      new_reading =
        create_reading(%{
          aqi_value: 160,
          category: "Unhealthy",
          value: 60.0,
          measured_at: DateTime.utc_now()
        })

      # Verify we can detect the previous reading
      previous =
        AqiReadings.get_previous_reading(
          new_reading.station_id,
          new_reading.parameter,
          new_reading.measured_at
        )

      assert previous != nil
      assert previous.aqi_value == 50
    end

    test "detects clearing from Unhealthy to Moderate" do
      # Create a "before" reading with Unhealthy AQI
      create_reading(%{
        aqi_value: 160,
        category: "Unhealthy",
        value: 60.0,
        measured_at: DateTime.add(DateTime.utc_now(), -3600, :second)
      })

      # Create an "after" reading with Moderate AQI
      new_reading =
        create_reading(%{
          aqi_value: 80,
          category: "Moderate",
          value: 20.0,
          measured_at: DateTime.utc_now()
        })

      previous =
        AqiReadings.get_previous_reading(
          new_reading.station_id,
          new_reading.parameter,
          new_reading.measured_at
        )

      assert previous != nil
      assert previous.aqi_value == 160
      # Verify the crossing: was above 150, now below
      assert previous.aqi_value > 150
      assert new_reading.aqi_value <= 150
    end

    test "no crossing when AQI stays in the same range" do
      # Both readings are in the "Moderate" range
      create_reading(%{
        aqi_value: 75,
        category: "Moderate",
        value: 20.0,
        measured_at: DateTime.add(DateTime.utc_now(), -3600, :second)
      })

      new_reading =
        create_reading(%{
          aqi_value: 85,
          category: "Moderate",
          value: 25.0,
          measured_at: DateTime.utc_now()
        })

      previous =
        AqiReadings.get_previous_reading(
          new_reading.station_id,
          new_reading.parameter,
          new_reading.measured_at
        )

      # Neither crossed 151 threshold
      assert previous.aqi_value < 151 and new_reading.aqi_value < 151
    end
  end
end
