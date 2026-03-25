# CM AQI — Chiang Mai Air Quality Alert System

> Real-time air quality monitoring and LINE notification alerts for Chiang Mai, Thailand.

![Elixir](https://img.shields.io/badge/Elixir-1.19+-4B275F?logo=elixir)
![Phoenix](https://img.shields.io/badge/Phoenix-1.8+-FD4F00?logo=phoenixframework)
![License](https://img.shields.io/badge/License-MIT-green)

---

## Why This Exists

Every year from **February through April**, northern Thailand experiences the infamous **burning season**. Agricultural burning, forest fires, and cross-border haze combine to create some of the worst air quality on the planet. During peak season, Chiang Mai's PM2.5 levels regularly exceed **200-300+ µg/m³** — far above the WHO guideline of 15 µg/m³.

CM AQI was built to help Chiang Mai residents and visitors:
- **Monitor** real-time air quality from official monitoring stations
- **Understand** what AQI levels mean for their health
- **Get notified** via LINE when conditions change significantly

This is an **open-source portfolio project** built with Elixir and Phoenix to demonstrate real-world use of GenServers, LiveView, PubSub, and external API integrations.

---

## Screenshots

> Screenshots will be added after deployment.

| Dashboard | Subscribe | LINE Alert |
|-----------|-----------|------------|
| *Coming soon* | *Coming soon* | *Coming soon* |

---

## Features

- **Real-time Dashboard** — LiveView-powered dashboard that updates automatically via WebSocket (no page refresh)
- **AQI Calculation** — US EPA breakpoint formula converts raw PM2.5/PM10 to standardized AQI values (0-500)
- **Color-coded Cards** — Each station shows current AQI with color-coded categories (Green to Maroon)
- **Burn Season Warning** — Automatic banner when any station exceeds AQI 150
- **Historical Charts** — Last 24 hours of AQI data per station using Chart.js
- **LINE Notifications** — Subscribe with your LINE account to receive push alerts when AQI crosses your threshold
- **LINE OAuth Login** — Authenticate with LINE Login (no password to manage)
- **Customizable Thresholds** — Choose your alert sensitivity (101, 151, 201, or 301)
- **GenServer Architecture** — Fault-tolerant background polling with automatic retry on failure
- **10-Minute Polling** — Fresh data from OpenAQ every 10 minutes with upsert (no duplicates)

---

## Architecture

```mermaid
graph LR
    subgraph External APIs
        OpenAQ["OpenAQ v3 API<br/>(PM2.5 & PM10 data)"]
        LINE_API["LINE Messaging API<br/>(Push notifications)"]
    end

    subgraph Elixir Application
        Poller["AqiPoller<br/>(GenServer)<br/>Polls every 10 min"]
        DB[(PostgreSQL<br/>aqi_readings<br/>line_users<br/>line_subscriptions)]
        PubSub["Phoenix PubSub<br/>(aqi:updates topic)"]
        Broadcaster["AlertBroadcaster<br/>(GenServer)<br/>Threshold detection"]
        Dashboard["LiveView Dashboard<br/>(Real-time UI)"]
        Subscribe["Subscribe Page<br/>(LINE Login + Preferences)"]
    end

    subgraph Users
        Browser["Web Browser"]
        LINE_App["LINE App<br/>(Notifications)"]
    end

    OpenAQ -->|"HTTP GET"| Poller
    Poller -->|"Upsert readings"| DB
    Poller -->|"Broadcast"| PubSub
    PubSub -->|"Subscribe"| Broadcaster
    PubSub -->|"Subscribe"| Dashboard
    Broadcaster -->|"Query subscribers"| DB
    Broadcaster -->|"Push message"| LINE_API
    LINE_API -->|"Notification"| LINE_App
    Dashboard -->|"WebSocket"| Browser
    Subscribe -->|"HTTP"| Browser

    style Poller fill:#4B275F,color:#fff
    style Broadcaster fill:#4B275F,color:#fff
    style PubSub fill:#FD4F00,color:#fff
    style Dashboard fill:#FD4F00,color:#fff
```

### Data Flow

1. **AqiPoller** (GenServer) polls OpenAQ every 10 minutes for Chiang Mai PM2.5 and PM10 data
2. Readings are upserted into PostgreSQL (duplicates are handled via unique constraint)
3. New readings are broadcast to the `"aqi:updates"` PubSub topic
4. **LiveView Dashboard** subscribes to PubSub and updates in real-time
5. **AlertBroadcaster** (GenServer) subscribes to PubSub and checks for threshold crossings
6. When a threshold is crossed, it queries active subscribers and sends LINE push notifications

---

## Local Development Setup

### Prerequisites

- **Elixir** 1.16+ (we recommend 1.19+)
- **Erlang/OTP** 26+ (we recommend 28+)
- **PostgreSQL** 14+
- **Git**

### Install Elixir (macOS)

```bash
# Using Homebrew
brew install elixir

# Verify installation
elixir --version
```

### Clone and Setup

```bash
# Clone the repository
git clone https://github.com/sitachanstudios/cm-aqi.git
cd cm-aqi

# Install Elixir dependencies
mix deps.get

# Create and migrate the database
# (Make sure PostgreSQL is running first!)
mix ecto.setup

# Start the Phoenix development server
mix phx.server
```

Now visit [http://localhost:4000](http://localhost:4000) in your browser.

### Running Tests

```bash
# Run all tests
mix test

# Run a specific test file
mix test test/cm_aqi/calculator_test.exs

# Run tests with verbose output
mix test --trace

# Run the linter
mix credo
```

---

## Environment Variables

| Variable | Required | Description | Example |
|----------|----------|-------------|---------|
| `DATABASE_URL` | Prod only | PostgreSQL connection URL | `ecto://user:pass@host/cm_aqi` |
| `SECRET_KEY_BASE` | Prod only | Phoenix secret (run `mix phx.gen.secret`) | `abc123...` |
| `PHX_HOST` | Prod only | Your app's hostname | `cm-aqi.fly.dev` |
| `PHX_SERVER` | Prod only | Enable the web server | `true` |
| `PORT` | No | HTTP port (default: 4000) | `4000` |
| `LINE_CHANNEL_ID` | For LINE features | LINE Login channel ID | `1234567890` |
| `LINE_CHANNEL_SECRET` | For LINE features | LINE Login channel secret | `abc123...` |
| `LINE_CHANNEL_ACCESS_TOKEN` | For LINE features | Messaging API access token | `abc123...` |
| `LINE_CALLBACK_URL` | For LINE features | OAuth callback URL | `https://cm-aqi.fly.dev/auth/line/callback` |

Copy `.env.example` to `.env` and fill in your values:

```bash
cp .env.example .env
```

---

## Getting LINE Developer Credentials

To enable LINE Login and push notifications, you need credentials from the LINE Developers Console.

### Step 1: Create a LINE Developers Account

1. Go to [https://developers.line.biz/](https://developers.line.biz/)
2. Log in with your LINE account
3. Create a new **Provider** (this represents your organization)

### Step 2: Create a LINE Login Channel

1. In your Provider, click **Create a new channel**
2. Select **LINE Login**
3. Fill in the required fields (channel name, description, etc.)
4. Note your **Channel ID** and **Channel Secret** — these are `LINE_CHANNEL_ID` and `LINE_CHANNEL_SECRET`
5. Under **LINE Login** settings:
   - Set the **Callback URL** to `http://localhost:4000/auth/line/callback` (for dev)
   - For production, add your production URL as well

### Step 3: Create a Messaging API Channel

1. In the same Provider, create another channel
2. Select **Messaging API**
3. Fill in the required fields
4. Go to the **Messaging API** tab
5. At the bottom, click **Issue** under "Channel access token (long-lived)"
6. Copy the token — this is your `LINE_CHANNEL_ACCESS_TOKEN`

### Step 4: Link the Channels

Both channels must be in the same Provider. The LINE Login channel handles authentication, and the Messaging API channel handles sending push notifications.

---

## Deployment to Fly.io

### Prerequisites

Install the Fly.io CLI:

```bash
# macOS
brew install flyctl

# Login to Fly.io
fly auth login
```

### Deploy

```bash
# Create the app (first time only)
fly launch --name cm-aqi --region sin --no-deploy

# Create a PostgreSQL database
fly postgres create --name cm-aqi-db --region sin
fly postgres attach cm-aqi-db

# Set environment variables
fly secrets set SECRET_KEY_BASE=$(mix phx.gen.secret)
fly secrets set LINE_CHANNEL_ID=your_id
fly secrets set LINE_CHANNEL_SECRET=your_secret
fly secrets set LINE_CHANNEL_ACCESS_TOKEN=your_token
fly secrets set LINE_CALLBACK_URL=https://cm-aqi.fly.dev/auth/line/callback

# Deploy
fly deploy

# Run database migrations
fly ssh console -C "/app/bin/migrate"
```

Your app should now be live at `https://cm-aqi.fly.dev`!

---

## Project Structure

```
cm-aqi/
├── lib/
│   ├── cm_aqi/                      # Business logic (non-web)
│   │   ├── aqi_readings/            # AQI data context
│   │   │   ├── calculator.ex        #   EPA AQI breakpoint formula
│   │   │   └── reading.ex           #   Ecto schema for readings
│   │   ├── subscriptions/           # Subscription context
│   │   │   ├── line_user.ex         #   Ecto schema for LINE users
│   │   │   └── line_subscription.ex #   Ecto schema for subscriptions
│   │   ├── http_client.ex           # HTTP client behaviour (interface)
│   │   ├── http_client/
│   │   │   └── req.ex               #   Real HTTP implementation (Req library)
│   │   ├── aqi_readings.ex          # AqiReadings context (public API)
│   │   ├── subscriptions.ex         # Subscriptions context (public API)
│   │   ├── line_client.ex           # LINE API client (OAuth + Messaging)
│   │   ├── aqi_poller.ex            # GenServer: polls OpenAQ every 10 min
│   │   ├── alert_broadcaster.ex     # GenServer: sends LINE alerts
│   │   ├── application.ex           # OTP application & supervision tree
│   │   └── repo.ex                  # Ecto database repo
│   └── cm_aqi_web/                  # Web layer
│       ├── live/
│       │   ├── dashboard_live.ex    #   Real-time AQI dashboard
│       │   ├── subscribe_live.ex    #   LINE subscription page
│       │   └── about_live.ex        #   About page
│       ├── controllers/
│       │   └── line_auth_controller.ex  # LINE OAuth flow
│       ├── components/              # Shared UI components
│       ├── router.ex                # URL routing
│       └── endpoint.ex              # HTTP endpoint config
├── priv/
│   └── repo/migrations/             # Database migrations
├── test/                            # ExUnit tests
├── config/                          # Environment-specific config
├── assets/                          # CSS and JavaScript
├── fly.toml                         # Fly.io deployment config
├── Dockerfile                       # Container build config
├── .env.example                     # Environment variable template
└── .credo.exs                       # Credo linter config
```

---

## Key Elixir Concepts Used

This project demonstrates many core Elixir/Phoenix concepts:

| Concept | Where Used | What It Does |
|---------|-----------|--------------|
| **GenServer** | `AqiPoller`, `AlertBroadcaster` | Long-running background processes with state |
| **Supervision Tree** | `Application` | Automatic restart on failure (fault tolerance) |
| **PubSub** | Poller to Dashboard/Broadcaster | Inter-process message broadcasting |
| **LiveView** | Dashboard, Subscribe, About | Real-time UI without JavaScript |
| **Ecto** | Schemas, Migrations, Contexts | Database ORM with changesets for validation |
| **Behaviours** | `HttpClient` | Interfaces for dependency injection |
| **Pattern Matching** | Everywhere | Elixir's primary control flow mechanism |
| **Pipe Operator** | Everywhere | `x \|> f() \|> g()` chains function calls |
| **with** | OAuth flow, API parsing | Chain operations that might fail |

---

## Contributing

Contributions are welcome! Here's how:

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/my-feature`
3. Make your changes
4. Run tests: `mix test`
5. Run the linter: `mix credo`
6. Format your code: `mix format`
7. Commit your changes: `git commit -m "Add my feature"`
8. Push to the branch: `git push origin feature/my-feature`
9. Open a Pull Request

### Code Style

- Run `mix format` before committing (enforced by CI)
- Run `mix credo` for style suggestions
- Add `@moduledoc` to every module
- Add `@doc` and `@spec` to public functions
- Write tests for new features

---

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.

---

Built with Elixir and Phoenix in Chiang Mai, Thailand.
