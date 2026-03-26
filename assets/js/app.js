// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/cm_aqi"
import topbar from "../vendor/topbar"

// ============================================================================
// LiveView Hooks
// ============================================================================
// Hooks let you run custom JavaScript when LiveView elements are mounted,
// updated, or destroyed. They bridge the gap between Elixir's server-side
// rendering and client-side JavaScript libraries (like Chart.js).
//
// In the template, you connect a hook with: phx-hook="HookName"
// The hook must be registered here in the LiveSocket configuration.

// Returns Bootstrap color for an AQI value, matching the server-side calculator.
function aqiColor(value) {
  if (value <= 50) return "#198754"   // Good — Bootstrap success
  if (value <= 100) return "#ffc107"  // Moderate — Bootstrap warning
  if (value <= 150) return "#fd7e14"  // Unhealthy for Sensitive — Bootstrap orange
  if (value <= 200) return "#dc3545"  // Unhealthy — Bootstrap danger
  if (value <= 300) return "#6f42c1"  // Very Unhealthy — Bootstrap purple
  return "#842029"                     // Hazardous — Bootstrap dark red
}

const Hooks = {
  // AqiChart: Renders a Chart.js line chart showing AQI history.
  // Each line segment is colored based on the AQI value at that point,
  // so you can see the air quality change visually over time.
  AqiChart: {
    mounted() {
      const canvas = this.el.querySelector("canvas")
      if (!canvas || typeof Chart === "undefined") return

      this.chart = new Chart(canvas.getContext("2d"), {
        type: "line",
        data: {
          labels: [],
          datasets: [{
            label: "AQI",
            data: [],
            // Use segment styling to color each line segment independently.
            // ctx.p1 is the endpoint of the segment — we color based on its AQI value.
            segment: {
              borderColor: ctx => aqiColor(ctx.p1.parsed.y),
              backgroundColor: ctx => {
                const color = aqiColor(ctx.p1.parsed.y)
                // Add transparency for the fill area
                return color + "20"
              }
            },
            // Default border color for the first point (segment colors override this)
            borderColor: "#198754",
            fill: true,
            tension: 0.3,
            pointRadius: 0,
            borderWidth: 2,
          }]
        },
        options: {
          responsive: true,
          maintainAspectRatio: false,
          plugins: {
            legend: { display: false },
            tooltip: {
              callbacks: {
                labelColor: function(context) {
                  const color = aqiColor(context.parsed.y)
                  return { borderColor: color, backgroundColor: color }
                }
              }
            }
          },
          scales: {
            x: {
              display: true,
              ticks: { maxTicksLimit: 6, font: { size: 10 } }
            },
            y: {
              display: true,
              beginAtZero: true,
              ticks: { font: { size: 10 } }
            }
          }
        }
      })

      // Listen for chart data pushed from the server
      this.handleEvent("chart_data:" + this.el.dataset.stationId, (data) => {
        this.chart.data.labels = data.labels
        this.chart.data.datasets[0].data = data.values
        this.chart.update()
      })
    },

    destroyed() {
      if (this.chart) {
        this.chart.destroy()
      }
    }
  },

  // AqiMap: Renders a Leaflet map with colored markers for each sensor station.
  AqiMap: {
    mounted() {
      if (typeof L === "undefined") return

      // Center on Chiang Mai
      this.map = L.map(this.el, {
        zoomControl: true,
        scrollWheelZoom: true,
      }).setView([18.79, 98.98], 12)

      L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
        attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>',
        maxZoom: 18,
      }).addTo(this.map)

      // Leaflet can miscalculate tile positions if the container size
      // isn't fully resolved when the map initializes. Calling
      // invalidateSize() after a frame ensures tiles render correctly.
      requestAnimationFrame(() => this.map.invalidateSize())

      this.markers = []
      this.heatLayer = null

      this.handleEvent("map_data", (data) => {
        // Clear old markers
        this.markers.forEach(m => m.remove())
        this.markers = []

        // Clear old heatmap
        if (this.heatLayer) {
          this.map.removeLayer(this.heatLayer)
          this.heatLayer = null
        }

        // Build heatmap data from active stations
        // Each point is [lat, lng, intensity] where intensity is AQI/500
        const heatPoints = []

        data.markers.forEach(station => {
          const color = station.color || "#808080"
          const isActive = station.active

          // Add to heatmap if active with valid AQI
          if (isActive && station.aqi != null) {
            // Normalize AQI to 0-1 range for heat intensity (cap at 500)
            const intensity = Math.min(station.aqi, 500) / 500
            heatPoints.push([station.lat, station.lng, intensity])
          }

          // Active stations: large, opaque. Inactive: smaller, semi-transparent.
          const marker = L.circleMarker([station.lat, station.lng], {
            radius: isActive ? 14 : 8,
            fillColor: color,
            color: "#fff",
            weight: isActive ? 2 : 1,
            opacity: isActive ? 1 : 0.6,
            fillOpacity: isActive ? 0.9 : 0.4,
          }).addTo(this.map)

          // Show AQI value on active markers, nothing on inactive
          if (isActive && station.aqi != null) {
            marker.bindTooltip(String(station.aqi), {
              permanent: true,
              direction: "center",
              className: "aqi-marker-label",
            })
          }

          marker.bindPopup(
            `<a href="/sensors/${station.id}" class="font-bold hover:underline">${station.name}</a><br/>` +
            (isActive
              ? `AQI: <strong style="color:${color}">${station.aqi || "—"}</strong><br/>${station.category || "No Data"}`
              : `<em style="color:#999">Offline</em>`)
          )

          // Click the marker circle itself to navigate to the detail page
          if (isActive && station.id) {
            marker.on("click", () => {
              window.location.href = "/sensors/" + station.id
            })
          }

          this.markers.push(marker)
        })

        // Add heatmap layer beneath the markers
        if (typeof L.heatLayer === "function" && heatPoints.length > 0) {
          this.heatLayer = L.heatLayer(heatPoints, {
            radius: 35,
            blur: 25,
            maxZoom: 15,
            max: 1.0,
            gradient: {
              0.0: "#198754",   // Good — green
              0.2: "#ffc107",   // Moderate — yellow
              0.3: "#fd7e14",   // USG — orange
              0.4: "#dc3545",   // Unhealthy — red
              0.6: "#6f42c1",   // Very Unhealthy — purple
              1.0: "#842029",   // Hazardous — dark red
            }
          }).addTo(this.map)
        }

        // Recalculate size after markers are added
        this.map.invalidateSize()
      })
    },

    destroyed() {
      if (this.map) {
        this.map.remove()
      }
    }
  },

  // SensorMap: A simple single-marker map for the sensor detail page.
  SensorMap: {
    mounted() {
      if (typeof L === "undefined") return

      const lat = parseFloat(this.el.dataset.lat)
      const lng = parseFloat(this.el.dataset.lng)
      if (isNaN(lat) || isNaN(lng)) return

      const color = this.el.dataset.color || "#808080"
      const aqi = this.el.dataset.aqi
      const name = this.el.dataset.name

      this.map = L.map(this.el).setView([lat, lng], 14)

      L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
        attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>',
        maxZoom: 18,
      }).addTo(this.map)

      const marker = L.circleMarker([lat, lng], {
        radius: 16,
        fillColor: color,
        color: "#fff",
        weight: 2,
        fillOpacity: 0.9,
      }).addTo(this.map)

      if (aqi) {
        marker.bindTooltip(aqi, {
          permanent: true,
          direction: "center",
          className: "aqi-marker-label",
        })
      }

      if (name) {
        marker.bindPopup(`<strong>${name}</strong>`)
      }

      requestAnimationFrame(() => this.map.invalidateSize())
    },

    destroyed() {
      if (this.map) this.map.remove()
    }
  }
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ...Hooks},
})

// ============================================================================
// Theme Toggle
// ============================================================================
// Handles the "phx:set-theme" custom event dispatched by the theme toggle buttons.
// Reads the chosen theme from the clicked button's data-phx-theme attribute,
// saves it to localStorage, and applies the data-theme attribute to <html>.

function applyTheme(setting) {
  localStorage.setItem("theme", setting)
  let theme
  if (setting === "system") {
    theme = window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light"
  } else {
    theme = setting
  }
  document.documentElement.setAttribute("data-theme", theme)
}

window.addEventListener("phx:set-theme", (e) => {
  const setting = e.target.dataset.phxTheme
  if (setting) applyTheme(setting)
})

// When the OS preference changes and the user has "system" selected, update live
window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => {
  if (localStorage.getItem("theme") === "system") applyTheme("system")
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

