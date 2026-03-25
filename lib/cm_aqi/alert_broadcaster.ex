defmodule CmAqi.AlertBroadcaster do
  @moduledoc """
  A GenServer that monitors AQI changes and sends LINE notifications when
  thresholds are crossed.

  ## How It Works

  1. Subscribes to the "aqi:updates" PubSub topic on startup
  2. When new readings arrive (broadcast by AqiPoller), checks each reading
  3. Compares the new AQI to the previous reading's AQI for that station
  4. If the AQI crossed a threshold boundary (e.g., went from 145 → 160,
     crossing the 151 "Unhealthy" threshold), triggers notifications
  5. Queries all active subscribers whose threshold is ≤ the new AQI
  6. Sends each subscriber a LINE push notification

  ## Threshold Crossing Detection

  We detect TWO types of crossings:
  - **Escalation**: AQI went UP past a threshold (air got worse)
  - **Clearing**: AQI went DOWN past the 150 mark (air improved to Moderate or better)

  We only notify on CROSSINGS, not on every reading. If the AQI stays at 160
  for 3 readings in a row, we only send one notification (on the first reading).

  ## Why a Separate GenServer?

  Separating the poller from the broadcaster follows the Single Responsibility
  Principle. The poller is responsible for fetching and storing data. The
  broadcaster is responsible for notification logic. This makes each easier
  to test and debug independently.
  """

  use GenServer
  require Logger

  alias CmAqi.AqiReadings
  alias CmAqi.AqiReadings.Calculator
  alias CmAqi.Subscriptions
  alias CmAqi.LineClient

  # The AQI thresholds we monitor for crossings
  @alert_thresholds [151, 201, 301]

  # The "clearing" threshold — when AQI drops below this, notify subscribers
  @clearing_threshold 150

  # ============================================================================
  # Client API
  # ============================================================================

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    Logger.info("AlertBroadcaster starting — subscribing to aqi:updates")

    # Subscribe to the PubSub topic. This means whenever AqiPoller broadcasts
    # {:readings_updated, readings}, this GenServer will receive it in handle_info.
    Phoenix.PubSub.subscribe(CmAqi.PubSub, "aqi:updates")

    {:ok, %{}}
  end

  @doc """
  Handles incoming reading updates from PubSub.

  This is triggered every time AqiPoller successfully fetches and stores new
  readings. We check each reading for threshold crossings.
  """
  @impl true
  def handle_info({:readings_updated, readings}, state) do
    Logger.debug(
      "AlertBroadcaster: Checking #{length(readings)} readings for threshold crossings"
    )

    # Process each reading — check if it crossed a threshold
    Enum.each(readings, &check_threshold_crossing/1)

    {:noreply, state}
  end

  # Catch-all for unexpected messages (good practice for GenServers)
  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  # Checks if a reading's AQI crossed a threshold compared to the previous reading.
  # Only checks PM2.5 readings (the primary health concern during burn season).
  @spec check_threshold_crossing(struct()) :: :ok
  defp check_threshold_crossing(%{parameter: "pm25", aqi_value: aqi_value} = reading)
       when not is_nil(aqi_value) do
    # Get the previous reading for this station to compare
    previous =
      AqiReadings.get_previous_reading(
        reading.station_id,
        reading.parameter,
        reading.measured_at
      )

    previous_aqi = if previous, do: previous.aqi_value, else: 0

    check_escalations(reading, previous_aqi)
    check_clearing(reading, previous_aqi)

    :ok
  end

  defp check_threshold_crossing(_reading), do: :ok

  # Check for escalation crossings (AQI going UP past a threshold)
  @spec check_escalations(struct(), integer()) :: :ok
  defp check_escalations(reading, previous_aqi) do
    Enum.each(@alert_thresholds, fn threshold ->
      if previous_aqi < threshold and reading.aqi_value >= threshold do
        Logger.warning(
          "AlertBroadcaster: AQI ESCALATION at #{reading.station_name} — " <>
            "#{previous_aqi} → #{reading.aqi_value} (crossed #{threshold})"
        )

        notify_subscribers(reading, :escalation)
      end
    end)
  end

  # Check for clearing (AQI dropping below the clearing threshold)
  @spec check_clearing(struct(), integer()) :: :ok
  defp check_clearing(reading, previous_aqi) do
    if previous_aqi > @clearing_threshold and reading.aqi_value <= @clearing_threshold do
      Logger.info(
        "AlertBroadcaster: AQI CLEARING at #{reading.station_name} — " <>
          "#{previous_aqi} → #{reading.aqi_value} (cleared below #{@clearing_threshold})"
      )

      notify_subscribers(reading, :clearing)
    end

    :ok
  end

  # Sends LINE notifications to all subscribers who should be notified for this reading.
  @spec notify_subscribers(struct(), :escalation | :clearing) :: :ok
  defp notify_subscribers(reading, alert_type) do
    subscribers = Subscriptions.get_subscribers_for_threshold(reading.aqi_value)

    Logger.info(
      "AlertBroadcaster: Notifying #{length(subscribers)} subscribers " <>
        "about #{alert_type} at #{reading.station_name}"
    )

    Enum.each(subscribers, fn {line_user_id, _display_name} ->
      # Build and send the LINE notification
      message = build_notification_message(reading, alert_type)

      case LineClient.send_push_message(line_user_id, message) do
        :ok ->
          Logger.debug("AlertBroadcaster: Sent notification to #{line_user_id}")

        {:error, reason} ->
          Logger.error("AlertBroadcaster: Failed to notify #{line_user_id} — #{inspect(reason)}")
      end
    end)

    :ok
  end

  # Builds the notification message payload for LINE.
  @spec build_notification_message(struct(), :escalation | :clearing) :: map()
  defp build_notification_message(reading, alert_type) do
    info = Calculator.category_info(reading.aqi_value)

    title =
      case alert_type do
        :escalation -> "⚠️ Air Quality Alert"
        :clearing -> "✅ Air Quality Improved"
      end

    %{
      title: title,
      aqi_value: reading.aqi_value,
      category: info.label,
      color: info.color,
      recommendation: info.recommendation,
      station_name: reading.station_name,
      measured_at: reading.measured_at,
      alert_type: alert_type
    }
  end
end
