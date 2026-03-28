defmodule CmAqiWeb.WeeklyLive do
  @moduledoc """
  LiveView for the Weekly AQI overview page at "/weekly".

  Shows a 7-day calendar of daily average AQI values with mini hourly charts.
  """

  use CmAqiWeb, :live_view

  alias CmAqi.AqiReadings
  alias CmAqi.AqiReadings.Calculator

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(CmAqi.PubSub, "aqi:updates")
    end

    days = AqiReadings.list_weekly_daily_averages()

    socket =
      assign(socket,
        page_title: "Weekly",
        meta_description:
          "Past 7 days of air quality in Chiang Mai. Daily average AQI values and hourly trends.",
        canonical_path: "/weekly",
        days: days
      )

    socket =
      if connected?(socket) do
        push_daily_chart_data(socket, days)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_info({:readings_updated, _readings}, socket) do
    days = AqiReadings.list_weekly_daily_averages()

    socket =
      socket
      |> assign(days: days)
      |> push_daily_chart_data(days)

    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="text-center">
        <h1 class="text-3xl font-bold">Weekly AQI Overview</h1>
        <p class="text-base-content/60 mt-1">
          Past 7 days of air quality in Chiang Mai
        </p>
      </div>

      <%= render_weekly_cards(assigns) %>
    </div>
    """
  end

  @doc false
  def render_weekly_cards(assigns) do
    ~H"""
    <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 xl:grid-cols-7 gap-4">
      <div :for={day <- @days} class="card bg-base-200 shadow-md overflow-hidden">
        <div class="h-2" style={"background-color: #{day_color(day.avg_aqi)}"}></div>
        <div class="card-body p-4">
          <div class="text-sm font-semibold text-base-content/60">
            {day_name(day.date)}
          </div>
          <div class="text-lg font-bold">
            {format_date(day.date)}
          </div>
          <div class="flex items-end gap-2 mt-1">
            <span class="text-3xl font-bold" style={"color: #{day_color(day.avg_aqi)}"}>
              {day.avg_aqi || "—"}
            </span>
            <span class="text-xs text-base-content/60 mb-1">AQI</span>
          </div>
          <span
            :if={day.avg_aqi}
            class="badge text-white text-xs whitespace-nowrap self-start"
            style={"background-color: #{day_color(day.avg_aqi)}"}
          >
            {Calculator.category_for_aqi(day.avg_aqi)}
          </span>
          <div
            id={"chart-day-#{day.date}"}
            phx-hook="AqiChart"
            phx-update="ignore"
            data-station-id={"day-#{day.date}"}
            class="mt-2 h-24"
          >
            <canvas></canvas>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp push_daily_chart_data(socket, days) do
    Enum.reduce(days, socket, fn day, sock ->
      labels = Enum.map(day.hourly, fn h -> "#{h.hour}:00" end)
      values = Enum.map(day.hourly, & &1.avg_aqi)
      push_event(sock, "chart_data:day-#{day.date}", %{labels: labels, values: values})
    end)
  end

  defp day_color(nil), do: "#808080"
  defp day_color(aqi), do: Calculator.color_for_aqi(aqi)

  defp day_name(date) do
    Calendar.strftime(date, "%A")
  end

  defp format_date(date) do
    day = date.day
    suffix = ordinal_suffix(day)
    Calendar.strftime(date, "%B #{day}#{suffix}")
  end

  defp ordinal_suffix(d) when d in [1, 21, 31], do: "st"
  defp ordinal_suffix(d) when d in [2, 22], do: "nd"
  defp ordinal_suffix(d) when d in [3, 23], do: "rd"
  defp ordinal_suffix(_), do: "th"
end
