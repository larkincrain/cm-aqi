defmodule CmAqi.AlertBroadcaster do
  @moduledoc """
  A GenServer that monitors city-wide AQI changes and sends LINE notifications
  when the average AQI crosses a subscriber's personal threshold.

  ## How It Works

  1. Subscribes to the "aqi:updates" PubSub topic on startup
  2. When new readings arrive, computes the city-wide average PM2.5 AQI
  3. Compares the new average to the previous average
  4. For each active subscriber, checks if their personal threshold was crossed
  5. Sends LINE push notifications for threshold crossings (escalation or clearing)

  ## Morning Alert (7am ICT)

  Every day at 7:00 AM ICT (00:00 UTC), this GenServer checks the current
  average AQI. If it's at or above a subscriber's threshold, they receive a
  morning briefing notification so they know the day is starting with poor air.

  ## Why City Average?

  Individual stations can spike or have sensor errors. Using the average across
  all Chiang Mai stations gives a more representative picture of city-wide air
  quality, which is what matters for deciding whether to stay indoors or wear
  a mask.
  """

  use GenServer
  require Logger

  alias CmAqi.AqiReadings
  alias CmAqi.AqiReadings.Calculator
  alias CmAqi.Subscriptions
  alias CmAqi.LineClient

  # Chiang Mai is UTC+7
  @ict_offset_hours 7

  # The hour (in ICT / local time) to send the morning alert
  @morning_alert_hour 7

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

    # Subscribe to the PubSub topic. Whenever AqiPoller broadcasts
    # {:readings_updated, readings}, this GenServer receives it in handle_info.
    Phoenix.PubSub.subscribe(CmAqi.PubSub, "aqi:updates")

    # Schedule the first morning alert
    schedule_morning_alert()

    {:ok, %{previous_avg_aqi: nil}}
  end

  @impl true

  # Handles incoming reading updates from PubSub.
  # Computes the city-wide average PM2.5 AQI and checks if any subscriber's
  # personal threshold was crossed compared to the previous average.
  def handle_info({:readings_updated, _readings}, state) do
    avg_aqi = AqiReadings.average_current_aqi()

    Logger.debug(
      "AlertBroadcaster: City average AQI = #{inspect(avg_aqi)} " <>
        "(previous = #{inspect(state.previous_avg_aqi)})"
    )

    previous = state.previous_avg_aqi

    if avg_aqi != nil and previous != nil do
      check_threshold_crossings(previous, avg_aqi)
    end

    {:noreply, %{state | previous_avg_aqi: avg_aqi}}
  end

  # Handles the scheduled 7am morning alert.
  # Checks the current city-wide average AQI. Any active subscriber whose
  # threshold is at or below the current average receives a morning briefing.
  def handle_info(:morning_alert, state) do
    Logger.info("AlertBroadcaster: Running 7am morning AQI check")

    avg_aqi = AqiReadings.average_current_aqi()

    if avg_aqi != nil do
      send_morning_alerts(avg_aqi)
    end

    # Schedule the next morning alert
    schedule_morning_alert()

    # Update previous_avg_aqi so the next poll doesn't re-trigger a crossing
    {:noreply, %{state | previous_avg_aqi: avg_aqi || state.previous_avg_aqi}}
  end

  # Catch-all for unexpected messages
  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ============================================================================
  # Private Functions — Threshold Crossing Detection
  # ============================================================================

  # Checks all active subscribers to see if the city average crossed their
  # personal threshold. Handles both escalations (air worsening) and
  # clearings (air improving).
  @spec check_threshold_crossings(integer(), integer()) :: :ok
  defp check_threshold_crossings(previous_avg, current_avg) do
    # Get all active subscribers (regardless of threshold) so we can check
    # each one's personal threshold against the crossing.
    all_subscribers = Subscriptions.get_all_active_subscribers()

    Enum.each(all_subscribers, fn {line_user_id, display_name, threshold} ->
      cond do
        # Escalation: average crossed UP past this subscriber's threshold
        previous_avg < threshold and current_avg >= threshold ->
          Logger.warning(
            "AlertBroadcaster: City avg AQI ESCALATION #{previous_avg} → #{current_avg} " <>
              "(crossed #{threshold} for #{display_name})"
          )

          send_alert(line_user_id, current_avg, :escalation)

        # Clearing: average crossed DOWN past this subscriber's threshold
        previous_avg >= threshold and current_avg < threshold ->
          Logger.info(
            "AlertBroadcaster: City avg AQI CLEARING #{previous_avg} → #{current_avg} " <>
              "(cleared #{threshold} for #{display_name})"
          )

          send_alert(line_user_id, current_avg, :clearing)

        true ->
          :ok
      end
    end)
  end

  # ============================================================================
  # Private Functions — Morning Alerts
  # ============================================================================

  # Sends morning briefing notifications to all subscribers whose threshold
  # is at or below the current average AQI.
  @spec send_morning_alerts(integer()) :: :ok
  defp send_morning_alerts(avg_aqi) do
    subscribers = Subscriptions.get_subscribers_for_threshold(avg_aqi)

    Logger.info(
      "AlertBroadcaster: Morning alert — city avg AQI #{avg_aqi}, " <>
        "notifying #{length(subscribers)} subscribers"
    )

    Enum.each(subscribers, fn {line_user_id, _display_name} ->
      send_alert(line_user_id, avg_aqi, :morning)
    end)
  end

  # ============================================================================
  # Private Functions — Sending Alerts
  # ============================================================================

  # Sends a single LINE notification for the given alert type.
  @spec send_alert(String.t(), integer(), :escalation | :clearing | :morning) :: :ok
  defp send_alert(line_user_id, avg_aqi, alert_type) do
    message = build_notification_message(avg_aqi, alert_type)

    case LineClient.send_push_message(line_user_id, message) do
      :ok ->
        Logger.debug("AlertBroadcaster: Sent #{alert_type} alert to #{line_user_id}")

      {:error, reason} ->
        Logger.error(
          "AlertBroadcaster: Failed to notify #{line_user_id} — #{inspect(reason)}"
        )
    end

    :ok
  end

  # Builds the notification message payload for LINE.
  @spec build_notification_message(integer(), :escalation | :clearing | :morning) :: map()
  defp build_notification_message(avg_aqi, alert_type) do
    info = Calculator.category_info(avg_aqi)

    title =
      case alert_type do
        :escalation -> "⚠️ Air Quality Alert"
        :clearing -> "✅ Air Quality Improved"
        :morning -> "🌅 Morning AQI Report"
      end

    %{
      title: title,
      aqi_value: avg_aqi,
      category: info.label,
      color: info.color,
      recommendation: info.recommendation,
      station_name: "Chiang Mai Average",
      measured_at: DateTime.utc_now(),
      alert_type: alert_type
    }
  end

  # ============================================================================
  # Private Functions — Scheduling
  # ============================================================================

  # Schedules a timer to fire at the next 7:00 AM ICT.
  # ICT is UTC+7, so 7am ICT = midnight (00:00) UTC.
  @spec schedule_morning_alert() :: reference()
  defp schedule_morning_alert do
    now_utc = DateTime.utc_now()

    # 7am ICT = 0am UTC (7 - 7 = 0)
    target_utc_hour = @morning_alert_hour - @ict_offset_hours

    # Build today's target time in UTC
    today_target =
      now_utc
      |> DateTime.to_date()
      |> DateTime.new!(Time.new!(target_utc_hour, 0, 0))

    # If we've already passed today's target, schedule for tomorrow
    next_target =
      if DateTime.compare(now_utc, today_target) == :lt do
        today_target
      else
        DateTime.add(today_target, 24 * 3600, :second)
      end

    delay_ms = DateTime.diff(next_target, now_utc, :millisecond)

    Logger.info(
      "AlertBroadcaster: Next morning alert scheduled in #{div(delay_ms, 60_000)} minutes " <>
        "(at #{next_target} UTC / 7:00 AM ICT)"
    )

    Process.send_after(self(), :morning_alert, delay_ms)
  end
end
