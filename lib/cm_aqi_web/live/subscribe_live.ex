defmodule CmAqiWeb.SubscribeLive do
  @moduledoc """
  LiveView for the subscription management page at "/subscribe".

  ## What This Page Does

  1. **Before login**: Shows a "Login with LINE" button
  2. **After login**: Shows the user's LINE profile and subscription options
  3. **When subscribed**: Shows their current threshold and an unsubscribe button

  ## Session-Based Authentication

  After a user completes the LINE OAuth flow (handled by LineAuthController),
  their LINE user database ID is stored in the Phoenix session. This LiveView
  reads that session value to determine if the user is logged in.

  ## Why LiveView Instead of a Controller?

  Even though this page doesn't need real-time updates, using LiveView gives us:
  - Instant UI feedback when clicking buttons (no full page reload)
  - Easy form handling with built-in validation display
  - Consistent architecture with the rest of the app
  """

  use CmAqiWeb, :live_view

  alias CmAqi.Subscriptions

  # ============================================================================
  # Lifecycle Callbacks
  # ============================================================================

  @impl true
  def mount(_params, session, socket) do
    # `session` contains data stored in the browser's cookie.
    # After LINE OAuth login, we store "line_user_id" in the session.
    line_user_db_id = Map.get(session, "line_user_id")

    socket =
      if line_user_db_id do
        # User is logged in — load their profile and subscription
        user = Subscriptions.get_line_user(line_user_db_id)
        subscription = if user, do: Subscriptions.get_subscription_for_user(user.id), else: nil

        assign(socket,
          logged_in: true,
          line_user: user,
          subscription: subscription,
          selected_threshold: if(subscription, do: subscription.alert_threshold, else: 151)
        )
      else
        # User is not logged in — show the login button
        assign(socket,
          logged_in: false,
          line_user: nil,
          subscription: nil,
          selected_threshold: 151
        )
      end

    {:ok,
     assign(socket,
       page_title: "Subscribe",
       meta_description:
         "Get LINE notifications when Chiang Mai air quality changes. Set your personal AQI alert threshold for burn season PM2.5 warnings.",
       canonical_path: "/subscribe"
     )}
  end

  # ============================================================================
  # Event Handlers
  # ============================================================================

  # Handles threshold selection button clicks.
  #
  # In LiveView, `phx-click="event_name"` in the template sends an event
  # to this `handle_event/3` callback. The `phx-value-threshold` attribute
  # sends the threshold value along with the event.
  @impl true
  def handle_event("select_threshold", %{"threshold" => threshold_str}, socket) do
    threshold = String.to_integer(threshold_str)
    {:noreply, assign(socket, selected_threshold: threshold)}
  end

  # Handles the "Save Subscription" button click.
  @impl true
  def handle_event("save_subscription", _params, socket) do
    user = socket.assigns.line_user

    if user do
      case Subscriptions.create_or_update_subscription(user.id, %{
             alert_threshold: socket.assigns.selected_threshold,
             active: true
           }) do
        {:ok, subscription} ->
          {:noreply,
           socket
           |> assign(subscription: subscription)
           |> put_flash(
             :info,
             "Subscription saved! You'll receive alerts when AQI reaches #{subscription.alert_threshold}."
           )}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to save subscription. Please try again.")}
      end
    else
      {:noreply, put_flash(socket, :error, "Please log in first.")}
    end
  end

  # Handles the unsubscribe button click.
  @impl true
  def handle_event("unsubscribe", _params, socket) do
    user = socket.assigns.line_user

    if user do
      case Subscriptions.unsubscribe(user.id) do
        {:ok, subscription} ->
          {:noreply,
           socket
           |> assign(subscription: subscription)
           |> put_flash(:info, "You've been unsubscribed. You won't receive alerts.")}

        _ ->
          {:noreply, put_flash(socket, :error, "Failed to unsubscribe.")}
      end
    else
      {:noreply, socket}
    end
  end

  # Handles the resubscribe button click.
  @impl true
  def handle_event("resubscribe", _params, socket) do
    user = socket.assigns.line_user

    if user do
      case Subscriptions.resubscribe(user.id) do
        {:ok, subscription} ->
          {:noreply,
           socket
           |> assign(subscription: subscription)
           |> put_flash(:info, "Welcome back! You'll receive alerts again.")}

        _ ->
          {:noreply, put_flash(socket, :error, "Failed to resubscribe.")}
      end
    else
      {:noreply, socket}
    end
  end

  # ============================================================================
  # Template
  # ============================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-xl mx-auto space-y-6">
      <div class="text-center">
        <h1 class="text-3xl font-bold">Get Air Quality Alerts</h1>
        <p class="text-base-content/60 mt-2">
          Receive LINE notifications when Chiang Mai's air quality changes.
        </p>
      </div>

      <%!-- Not Logged In State --%>
      <div :if={!@logged_in} class="card bg-base-200 shadow-md">
        <div class="card-body items-center text-center">
          <h2 class="card-title">Connect Your LINE Account</h2>
          <p class="text-base-content/60">
            Log in with LINE to set up personalized air quality alerts.
            We'll send you a notification when the AQI crosses your chosen threshold.
          </p>
          <div class="card-actions mt-4">
            <%!--
              This is a regular link (not a LiveView navigation).
              It goes to our LineAuthController which redirects to LINE's OAuth page.
            --%>
            <a href="/auth/line" class="btn btn-primary btn-lg gap-2">
              <svg class="w-6 h-6" viewBox="0 0 24 24" fill="currentColor">
                <path d="M12 2C6.48 2 2 5.64 2 10.14c0 3.87 3.44 7.12 8.09 7.73.31.07.74.21.85.47.1.24.06.61.03.85l-.14.84c-.04.24-.19.95.83.52s5.52-3.27 7.53-5.6C21.19 12.93 22 11.11 22 10.14 22 5.64 17.52 2 12 2z" />
              </svg>
              Login with LINE
            </a>
          </div>
        </div>
      </div>

      <%!-- Logged In State --%>
      <div :if={@logged_in && @line_user} class="space-y-4">
        <%!-- User Profile Card --%>
        <div class="card bg-base-200 shadow-md">
          <div class="card-body">
            <div class="flex items-center gap-4">
              <div class="avatar">
                <div class="w-16 rounded-full">
                  <img
                    :if={@line_user.picture_url}
                    src={@line_user.picture_url}
                    alt={@line_user.display_name}
                  />
                </div>
              </div>
              <div>
                <h2 class="text-xl font-bold">{@line_user.display_name}</h2>
                <p class="text-sm text-base-content/60">Connected via LINE</p>
              </div>
            </div>
          </div>
        </div>

        <%!-- Subscription Preferences --%>
        <div class="card bg-base-200 shadow-md">
          <div class="card-body">
            <h2 class="card-title">Alert Threshold</h2>
            <p class="text-sm text-base-content/60 mb-4">
              Choose the minimum AQI level at which you want to be notified.
              Lower = more notifications, higher = only severe alerts.
            </p>

            <%!-- Threshold Selection Buttons --%>
            <div class="grid grid-cols-2 gap-2">
              <button
                phx-click="select_threshold"
                phx-value-threshold="101"
                class={"btn #{if @selected_threshold == 101, do: "btn-warning", else: "btn-outline"}"}
              >
                <div class="text-left">
                  <div class="font-bold">AQI 101+</div>
                  <div class="text-xs opacity-70">Unhealthy for Sensitive Groups</div>
                </div>
              </button>

              <button
                phx-click="select_threshold"
                phx-value-threshold="151"
                class={"btn #{if @selected_threshold == 151, do: "btn-error", else: "btn-outline"}"}
              >
                <div class="text-left">
                  <div class="font-bold">AQI 151+</div>
                  <div class="text-xs opacity-70">Unhealthy</div>
                </div>
              </button>

              <button
                phx-click="select_threshold"
                phx-value-threshold="201"
                class={"btn #{if @selected_threshold == 201, do: "btn-secondary", else: "btn-outline"}"}
              >
                <div class="text-left">
                  <div class="font-bold">AQI 201+</div>
                  <div class="text-xs opacity-70">Very Unhealthy</div>
                </div>
              </button>

              <button
                phx-click="select_threshold"
                phx-value-threshold="301"
                class={"btn #{if @selected_threshold == 301, do: "btn-accent", else: "btn-outline"}"}
              >
                <div class="text-left">
                  <div class="font-bold">AQI 301+</div>
                  <div class="text-xs opacity-70">Hazardous Only</div>
                </div>
              </button>
            </div>

            <%!-- Save / Unsubscribe Actions --%>
            <div class="card-actions mt-4">
              <button
                :if={@subscription == nil || @subscription.active}
                phx-click="save_subscription"
                class="btn btn-primary"
              >
                {if @subscription, do: "Update Subscription", else: "Subscribe"}
              </button>

              <button
                :if={@subscription && @subscription.active}
                phx-click="unsubscribe"
                class="btn btn-ghost text-error"
              >
                Unsubscribe
              </button>

              <button
                :if={@subscription && !@subscription.active}
                phx-click="resubscribe"
                class="btn btn-primary"
              >
                Resubscribe
              </button>
            </div>

            <%!-- Current Status --%>
            <div :if={@subscription} class="mt-2 text-sm">
              <span :if={@subscription.active} class="badge badge-success gap-1">
                Active — alerts at AQI {@subscription.alert_threshold}+
              </span>
              <span :if={!@subscription.active} class="badge badge-ghost gap-1">
                Paused — no alerts
              </span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
