defmodule CmAqi.LineClient do
  @moduledoc """
  Client for the LINE Messaging API and LINE Login OAuth2.

  ## LINE Platform Overview

  LINE provides two separate APIs that we use:

  ### 1. LINE Login (OAuth2)
  Lets users authenticate with their LINE account. The flow is:
  1. User clicks "Login with LINE" → we redirect to LINE's auth page
  2. User approves → LINE redirects back to our callback URL with a `code`
  3. We exchange the `code` for an access token
  4. We use the token to fetch the user's profile (ID, name, picture)

  ### 2. LINE Messaging API
  Lets us send push notifications to users. We use "push messages" which
  can be sent to users at any time (unlike "reply messages" which can only
  be sent in response to a user's message).

  ## Configuration

  All LINE credentials come from environment variables:
  - `LINE_CHANNEL_ID` — Your LINE Login channel ID
  - `LINE_CHANNEL_SECRET` — Your LINE Login channel secret
  - `LINE_CHANNEL_ACCESS_TOKEN` — Your Messaging API channel access token
  - `LINE_CALLBACK_URL` — Where LINE redirects after login (e.g., http://localhost:4000/auth/line/callback)

  ## LINE Flex Messages

  LINE supports rich "Flex Messages" — custom JSON layouts with colors,
  images, and buttons. We use these for AQI alerts to show a color-coded
  card with the AQI value, category, and health recommendation.
  """

  require Logger

  # ============================================================================
  # LINE Login OAuth2
  # ============================================================================

  @doc """
  Generates the URL to redirect users to for LINE Login.

  This is step 1 of the OAuth2 flow. We construct a URL to LINE's authorization
  page with our channel ID and callback URL. The `state` parameter is a random
  string used to prevent CSRF attacks.

  ## Parameters

  - `state` - A random string for CSRF protection (stored in the session)

  ## Returns

  A URL string that the user should be redirected to.
  """
  @spec authorize_url(String.t()) :: String.t()
  def authorize_url(state) do
    config = line_config()

    params =
      URI.encode_query(%{
        "response_type" => "code",
        "client_id" => config[:channel_id],
        "redirect_uri" => config[:callback_url],
        "state" => state,
        "scope" => "profile openid"
      })

    "https://access.line.me/oauth2/v2.1/authorize?#{params}"
  end

  @doc """
  Exchanges an OAuth authorization code for an access token.

  This is step 3 of the OAuth2 flow. After the user approves on LINE's page,
  LINE redirects to our callback URL with a `code` parameter. We exchange
  this short-lived code for an access token.

  ## Parameters

  - `code` - The authorization code from LINE's redirect

  ## Returns

  - `{:ok, %{"access_token" => "...", ...}}` on success
  - `{:error, reason}` on failure
  """
  @spec exchange_token(String.t()) :: {:ok, map()} | {:error, any()}
  def exchange_token(code) do
    config = line_config()

    # LINE's token endpoint requires form-urlencoded data (NOT JSON).
    # We use Req directly here because our HttpClient.post/3 sends JSON.
    form_body = %{
      "grant_type" => "authorization_code",
      "code" => code,
      "redirect_uri" => config[:callback_url],
      "client_id" => config[:channel_id],
      "client_secret" => config[:channel_secret]
    }

    case Req.post("https://api.line.me/oauth2/v2.1/token", form: form_body) do
      {:ok, %Req.Response{status: 200, body: response_body}} when is_map(response_body) ->
        {:ok, response_body}

      {:ok, %Req.Response{status: 200, body: response_body}} when is_binary(response_body) ->
        Jason.decode(response_body)

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("LINE token exchange failed: status=#{status} body=#{inspect(body)}")
        {:error, "LINE API returned status #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Fetches the user's LINE profile using their access token.

  This is step 4 of the OAuth2 flow. With the access token, we can call
  LINE's profile API to get the user's ID, display name, and picture URL.

  ## Parameters

  - `access_token` - The OAuth access token from `exchange_token/1`

  ## Returns

  - `{:ok, %{"userId" => "U...", "displayName" => "...", "pictureUrl" => "..."}}` on success
  - `{:error, reason}` on failure
  """
  @spec get_profile(String.t()) :: {:ok, map()} | {:error, any()}
  def get_profile(access_token) do
    client = CmAqi.HttpClient.client()

    case client.get(
           "https://api.line.me/v2/profile",
           [{"Authorization", "Bearer #{access_token}"}]
         ) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        Jason.decode(body)

      {:ok, %{status: status}} ->
        {:error, "LINE profile API returned status #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ============================================================================
  # LINE Messaging API — Push Notifications
  # ============================================================================

  @doc """
  Sends a push message to a LINE user.

  Push messages can be sent at any time without the user initiating a conversation.
  We use this to send AQI alerts when thresholds are crossed.

  ## Parameters

  - `line_user_id` - The recipient's LINE user ID (starts with "U")
  - `message_data` - A map with alert information (built by AlertBroadcaster)

  ## Returns

  - `:ok` on success
  - `{:error, reason}` on failure
  """
  @spec send_push_message(String.t(), map()) :: :ok | {:error, any()}
  def send_push_message(line_user_id, message_data) do
    config = line_config()
    client = CmAqi.HttpClient.client()

    # Build the LINE Flex Message (a rich, formatted card)
    flex_message = build_flex_message(message_data)

    body = %{
      "to" => line_user_id,
      "messages" => [flex_message]
    }

    headers = [
      {"Authorization", "Bearer #{config[:channel_access_token]}"},
      {"Content-Type", "application/json"}
    ]

    case client.post("https://api.line.me/v2/bot/message/push", body, headers) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: status, body: resp_body}} ->
        Logger.error("LINE push failed: status=#{status} body=#{inspect(resp_body)}")
        {:error, "LINE API returned status #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ============================================================================
  # LINE Flex Message Builder
  # ============================================================================

  # Builds a LINE Flex Message JSON structure for an AQI alert.
  #
  # Flex Messages are LINE's rich message format — they let you create custom
  # card layouts with colors, text, and buttons. The structure is deeply nested
  # JSON that LINE renders as a beautiful card in the chat.
  #
  # Docs: https://developers.line.biz/en/docs/messaging-api/flex-message-elements/
  @spec build_flex_message(map()) :: map()
  defp build_flex_message(message_data) do
    %{
      "type" => "flex",
      "altText" => "#{message_data.title} — AQI #{message_data.aqi_value}",
      "contents" => %{
        "type" => "bubble",
        "header" => %{
          "type" => "box",
          "layout" => "vertical",
          "backgroundColor" => message_data.color,
          "contents" => [
            %{
              "type" => "text",
              "text" => message_data.title,
              "color" => "#FFFFFF",
              "weight" => "bold",
              "size" => "lg"
            }
          ]
        },
        "body" => %{
          "type" => "box",
          "layout" => "vertical",
          "spacing" => "md",
          "contents" => [
            %{
              "type" => "text",
              "text" => "AQI #{message_data.aqi_value}",
              "size" => "3xl",
              "weight" => "bold",
              "align" => "center"
            },
            %{
              "type" => "text",
              "text" => message_data.category,
              "size" => "lg",
              "align" => "center",
              "color" => message_data.color
            },
            %{
              "type" => "separator"
            },
            %{
              "type" => "text",
              "text" => "📍 #{message_data.station_name}",
              "size" => "sm",
              "color" => "#666666"
            },
            %{
              "type" => "text",
              "text" => "🕐 #{format_time(message_data.measured_at)}",
              "size" => "sm",
              "color" => "#666666"
            },
            %{
              "type" => "separator"
            },
            %{
              "type" => "text",
              "text" => message_data.recommendation,
              "size" => "sm",
              "wrap" => true,
              "color" => "#333333"
            }
          ]
        },
        "footer" => %{
          "type" => "box",
          "layout" => "vertical",
          "contents" => [
            %{
              "type" => "button",
              "action" => %{
                "type" => "uri",
                "label" => "View Live Dashboard",
                "uri" => dashboard_url()
              },
              "style" => "primary",
              "color" => message_data.color
            }
          ]
        }
      }
    }
  end

  # Formats a DateTime for display in the LINE message.
  @spec format_time(DateTime.t()) :: String.t()
  defp format_time(%DateTime{} = dt) do
    # Convert UTC to Chiang Mai time (UTC+7)
    # Elixir's Calendar module handles time formatting
    shifted = DateTime.add(dt, 7 * 3600, :second)

    Calendar.strftime(shifted, "%B %d, %Y at %I:%M %p") <> " (ICT)"
  end

  defp format_time(_), do: "Unknown time"

  # Gets the dashboard URL for the "View Live Dashboard" button.
  @spec dashboard_url() :: String.t()
  defp dashboard_url do
    config = line_config()
    # Derive the base URL from the callback URL
    uri = URI.parse(config[:callback_url])

    "#{uri.scheme}://#{uri.host}#{if uri.port != 80 and uri.port != 443, do: ":#{uri.port}", else: ""}"
  end

  # Reads LINE configuration from the application config.
  @spec line_config() :: keyword()
  defp line_config do
    Application.get_env(:cm_aqi, :line, [])
  end
end
