defmodule CmAqiWeb.AboutLive do
  @moduledoc """
  LiveView for the About page at "/about".

  This is a simple, mostly-static page explaining the project, the Chiang Mai
  burn season context, and the AQI scale. We use LiveView instead of a plain
  controller so we can share the same layout and routing conventions.
  """

  use CmAqiWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "About",
       meta_description:
         "Learn about CM AQI, Chiang Mai's burn season, the US EPA Air Quality Index scale, and how this real-time air quality monitoring app works.",
       canonical_path: "/about"
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-3xl mx-auto space-y-8">
      <%!-- Hero Section --%>
      <div class="text-center">
        <h1 class="text-4xl font-bold">About CM AQI</h1>
        <p class="text-lg text-base-content/60 mt-2">
          Real-time air quality monitoring for Chiang Mai, Thailand
        </p>
      </div>

      <%!-- Burn Season Context --%>
      <div class="card bg-base-200 shadow-md">
        <div class="card-body">
          <h2 class="card-title text-2xl">The Chiang Mai Burn Season</h2>
          <div class="prose max-w-none">
            <p>
              Every year from approximately <strong>February through April</strong>, northern
              Thailand experiences what locals call the "burning season." Agricultural burning,
              forest fires, and cross-border haze combine to create some of the worst air
              quality in the world.
            </p>
            <p>
              During peak burn season, Chiang Mai's PM2.5 levels regularly exceed
              <strong>200-300+ µg/m³</strong>
              — far above the WHO guideline of 15 µg/m³
              for 24-hour exposure. At these levels, the air quality is classified as
              "Very Unhealthy" or "Hazardous" and poses serious health risks.
            </p>
            <p>
              This project was built to help residents and visitors stay informed about
              current air quality conditions and receive timely notifications when
              conditions change significantly.
            </p>
          </div>
        </div>
      </div>

      <%!-- AQI Scale Explanation --%>
      <div class="card bg-base-200 shadow-md">
        <div class="card-body">
          <h2 class="card-title text-2xl">Understanding the AQI Scale</h2>
          <p class="text-base-content/60 mb-4">
            The US EPA Air Quality Index (AQI) converts raw pollutant concentrations
            into a standardized 0-500 scale:
          </p>

          <div class="space-y-3">
            <div class="flex items-start gap-3 p-3 rounded-lg bg-base-300">
              <span class="badge text-white shrink-0" style="background-color: #198754">
                0–50
              </span>
              <div>
                <div class="font-semibold">Good</div>
                <div class="text-sm text-base-content/70">
                  Air quality is satisfactory. Enjoy outdoor activities!
                </div>
              </div>
            </div>
            <div class="flex items-start gap-3 p-3 rounded-lg bg-base-300">
              <span class="badge shrink-0" style="background-color: #ffc107">
                51–100
              </span>
              <div>
                <div class="font-semibold">Moderate</div>
                <div class="text-sm text-base-content/70">
                  Acceptable. Unusually sensitive people should limit prolonged outdoor exertion.
                </div>
              </div>
            </div>
            <div class="flex items-start gap-3 p-3 rounded-lg bg-base-300">
              <span class="badge text-white shrink-0" style="background-color: #fd7e14">
                101–150
              </span>
              <div>
                <div class="font-semibold">Unhealthy for Sensitive Groups</div>
                <div class="text-sm text-base-content/70">
                  Sensitive groups may experience health effects. Consider wearing a mask.
                </div>
              </div>
            </div>
            <div class="flex items-start gap-3 p-3 rounded-lg bg-base-300">
              <span class="badge text-white shrink-0" style="background-color: #dc3545">
                151–200
              </span>
              <div>
                <div class="font-semibold">Unhealthy</div>
                <div class="text-sm text-base-content/70">
                  Everyone may begin to experience health effects. Wear a mask outdoors.
                </div>
              </div>
            </div>
            <div class="flex items-start gap-3 p-3 rounded-lg bg-base-300">
              <span class="badge text-white shrink-0" style="background-color: #6f42c1">
                201–300
              </span>
              <div>
                <div class="font-semibold">Very Unhealthy</div>
                <div class="text-sm text-base-content/70">
                  Health alert: more serious effects for everyone. Avoid outdoor activity.
                </div>
              </div>
            </div>
            <div class="flex items-start gap-3 p-3 rounded-lg bg-base-300">
              <span class="badge text-white shrink-0" style="background-color: #842029">
                301–500
              </span>
              <div>
                <div class="font-semibold">Hazardous</div>
                <div class="text-sm text-base-content/70">
                  Health emergency. Stay indoors with air purification.
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>

      <%!-- How It Works --%>
      <div class="card bg-base-200 shadow-md">
        <div class="card-body">
          <h2 class="card-title text-2xl">How It Works</h2>
          <div class="prose max-w-none">
            <ol>
              <li>
                <strong>Data Collection</strong>
                — Every 10 minutes, we poll the
                <a href="https://openaq.org" class="link link-primary" target="_blank">OpenAQ</a>
                API for PM2.5 and PM10 readings from monitoring stations in Chiang Mai.
              </li>
              <li>
                <strong>AQI Calculation</strong> — Raw concentrations are converted to
                US EPA AQI values using the official breakpoint formula.
              </li>
              <li>
                <strong>Real-time Dashboard</strong> — This website updates automatically
                via WebSocket (Phoenix LiveView) — no page refresh needed.
              </li>
              <li>
                <strong>LINE Notifications</strong> — Subscribe with your LINE account
                to receive push notifications when the AQI crosses your chosen threshold.
              </li>
            </ol>
          </div>
        </div>
      </div>

      <%!-- Fire Detection --%>
      <div class="card bg-base-200 shadow-md">
        <div class="card-body">
          <h2 class="card-title text-2xl">Fire Detection Data</h2>
          <div class="prose max-w-none">
            <p>
              During burn season, knowing where active fires are burning is just as important
              as knowing the AQI. Our map overlay shows real-time fire detections across
              northern Thailand so you can see what's contributing to the haze.
            </p>
            <h3>Data Source</h3>
            <p>
              Fire locations come from
              <a href="https://firms.modaps.eosdis.nasa.gov/" class="link link-primary" target="_blank">
                NASA FIRMS</a>
              (Fire Information for Resource Management System). Specifically, we use the
              <strong>VIIRS</strong> (Visible Infrared Imaging Radiometer Suite) instrument
              aboard the Suomi NPP satellite, which detects thermal hotspots from orbit.
            </p>
            <h3>How We Collect It</h3>
            <p>
              Every <strong>30 minutes</strong>, we poll the FIRMS API for near-real-time
              fire detections within a bounding box covering northern Thailand. The API
              returns CSV data including each fire's latitude, longitude, thermal brightness
              (in Kelvin), and detection confidence. We keep the most recent
              <strong>2 days</strong> of detections.
            </p>
            <h3>How We Store It</h3>
            <p>
              Unlike AQI sensor readings, fire data is <strong>ephemeral</strong> — it's held
              in memory only and is not persisted to the database. Fires are transient by
              nature; detections from days ago aren't actionable. When the application
              restarts, fresh data is fetched from NASA within the first polling cycle.
            </p>
            <h3>How It Reaches Your Map</h3>
            <p>
              To keep things efficient, fire data is loaded <strong>lazily</strong>. When you
              open the map or pan to a new area, your browser tells the server what area is
              visible. The server filters the fire detections to only those within your
              viewport and pushes them over the WebSocket — so you only download what you
              can actually see. When new detections arrive from NASA, they're broadcast to
              all connected users in real time via PubSub.
            </p>
          </div>
        </div>
      </div>

      <%!-- Tech Stack --%>
      <div class="card bg-base-200 shadow-md">
        <div class="card-body">
          <h2 class="card-title text-2xl">Built With</h2>
          <div class="flex flex-wrap gap-2">
            <span class="badge badge-lg badge-primary">Elixir</span>
            <span class="badge badge-lg badge-primary">Phoenix</span>
            <span class="badge badge-lg badge-primary">LiveView</span>
            <span class="badge badge-lg badge-secondary">PostgreSQL</span>
            <span class="badge badge-lg badge-secondary">Tailwind CSS</span>
            <span class="badge badge-lg badge-accent">OpenAQ API</span>
            <span class="badge badge-lg badge-accent">LINE Messaging API</span>
            <span class="badge badge-lg badge-ghost">Chart.js</span>
          </div>
        </div>
      </div>

      <%!-- Links --%>
      <div class="text-center space-y-2">
        <p>
          <a
            href="https://github.com/sitachanstudios/cm-aqi"
            class="btn btn-outline gap-2"
            target="_blank"
          >
            <svg class="w-5 h-5" fill="currentColor" viewBox="0 0 24 24">
              <path d="M12 0c-6.626 0-12 5.373-12 12 0 5.302 3.438 9.8 8.207 11.387.599.111.793-.261.793-.577v-2.234c-3.338.726-4.033-1.416-4.033-1.416-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.107-.775.418-1.305.762-1.604-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23.957-.266 1.983-.399 3.003-.404 1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222v3.293c0 .319.192.694.801.576 4.765-1.589 8.199-6.086 8.199-11.386 0-6.627-5.373-12-12-12z" />
            </svg>
            View on GitHub
          </a>
        </p>
        <p class="text-sm text-base-content/40">
          Licensed under MIT. Contributions welcome!
        </p>
      </div>
    </div>
    """
  end
end
