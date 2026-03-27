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

  // AqiMap: Renders a Leaflet map with colored markers, heatmap, and fire dots.
  AqiMap: {
    mounted() {
      if (typeof L === "undefined") return

      this.map = L.map(this.el, {
        zoomControl: true,
        scrollWheelZoom: true,
      }).setView([18.79, 98.98], 12)

      L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
        attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>',
        maxZoom: 18,
      }).addTo(this.map)

      this.markers = []
      this.fireMarkers = []
      this.heatLayer = null
      this._pendingMapData = null
      this._pendingFireData = null
      this._mapReady = false

      // Wait for the container to have real dimensions before rendering
      // layers. Without this, leaflet.heat crashes on a 0-height canvas.
      const waitForSize = () => {
        this.map.invalidateSize()
        if (this.el.clientHeight > 0 && this.el.clientWidth > 0) {
          this._mapReady = true
          if (this._pendingMapData) {
            this._processMapData(this._pendingMapData)
            this._pendingMapData = null
          }
          if (this._pendingFireData) {
            this._processFireData(this._pendingFireData)
            this._pendingFireData = null
          }
        } else {
          requestAnimationFrame(waitForSize)
        }
      }
      requestAnimationFrame(waitForSize)

      this.handleEvent("map_data", (data) => {
        if (!this._mapReady) { this._pendingMapData = data; return }
        this._processMapData(data)
      })

      this.handleEvent("fire_data", (data) => {
        if (!this._mapReady) { this._pendingFireData = data; return }
        this._processFireData(data)
      })

      // Request fires for the current viewport. Fires are loaded lazily —
      // the client tells the server what area is visible, and the server
      // responds with only the fires in that bounding box.
      this._requestFires = () => {
        const b = this.map.getBounds()
        this.pushEvent("request_fires", {
          bounds: {
            south: b.getSouth(),
            north: b.getNorth(),
            west: b.getWest(),
            east: b.getEast()
          }
        })
      }

      // Request fires on initial load and whenever the map is panned/zoomed
      this.map.on("moveend", () => this._requestFires())
      // Initial request after map is ready
      this.map.whenReady(() => this._requestFires())
    },

    _processMapData(data) {
      this.markers.forEach(m => m.remove())
      this.markers = []

      if (this.heatLayer) {
        this.map.removeLayer(this.heatLayer)
        this.heatLayer = null
      }

      const heatPoints = []

      data.markers.forEach(station => {
        const color = station.color || "#808080"
        const isActive = station.active
        const isInner = station.within_50km

        if (isActive && station.aqi != null) {
          const intensity = Math.min(station.aqi, 500) / 500
          heatPoints.push([station.lat, station.lng, intensity])
        }

        let radius, weight, opacity, fillOpacity
        if (isActive && isInner) {
          radius = 14; weight = 2; opacity = 1; fillOpacity = 0.9
        } else if (isActive) {
          radius = 8; weight = 1; opacity = 0.8; fillOpacity = 0.7
        } else {
          radius = 5; weight = 1; opacity = 0.4; fillOpacity = 0.3
        }

        const marker = L.circleMarker([station.lat, station.lng], {
          radius, fillColor: color, color: "#fff", weight, opacity, fillOpacity,
        }).addTo(this.map)

        if (isActive && isInner && station.aqi != null) {
          marker.bindTooltip(String(station.aqi), {
            permanent: true, direction: "center", className: "aqi-marker-label",
          })
        }

        marker.bindPopup(
          `<a href="/sensors/${station.id}" class="font-bold hover:underline">${station.name}</a><br/>` +
          (isActive
            ? `AQI: <strong style="color:${color}">${station.aqi || "—"}</strong><br/>${station.category || "No Data"}`
            : `<em style="color:#999">Offline</em>`)
        )

        if (isActive && station.id) {
          marker.on("click", () => { window.location.href = "/sensors/" + station.id })
        }

        this.markers.push(marker)
      })

      // Defer heatmap to next frame — the container must be fully painted
      // before leaflet.heat can call getImageData on the canvas.
      if (typeof L.heatLayer === "function" && heatPoints.length > 0) {
        this._pendingHeatPoints = heatPoints
        setTimeout(() => {
          if (!this._pendingHeatPoints) return
          try {
            this.map.invalidateSize()

            if (!this.map.getPane("heatPane")) {
              this.map.createPane("heatPane")
              this.map.getPane("heatPane").style.zIndex = 450
            }

            const heatRadius = this._calculateHeatRadius(this._pendingHeatPoints)

            this.heatLayer = L.heatLayer(this._pendingHeatPoints, {
              radius: heatRadius,
              blur: Math.round(heatRadius * 0.6),
              maxZoom: 12,
              max: 1.0,
              minOpacity: 0.4,
              pane: "heatPane",
              gradient: {
                0.0: "#198754", 0.2: "#ffc107", 0.3: "#fd7e14",
                0.4: "#dc3545", 0.6: "#6f42c1", 1.0: "#842029",
              }
            }).addTo(this.map)
          } catch (e) {
            console.warn("[AqiMap] Heatmap render deferred — container not ready:", e.message)
          }
          this._pendingHeatPoints = null
        }, 100)
      }

      this.map.invalidateSize()
    },

    _processFireData(data) {
      console.log("[AqiMap] _processFireData called with", data.fires?.length, "fires")
      this.fireMarkers.forEach(m => m.remove())
      this.fireMarkers = []

      if (!data.fires || data.fires.length === 0) {
        console.log("[AqiMap] No fire data to render")
        return
      }

      if (!this.map.getPane("firePane")) {
        this.map.createPane("firePane")
        this.map.getPane("firePane").style.zIndex = 500
      }

      data.fires.forEach(fire => {
        const marker = L.circleMarker([fire.la, fire.ln], {
          radius: 4, fillColor: "#ff6600", color: "#cc3300",
          weight: 1, fillOpacity: 0.8, pane: "firePane",
        }).addTo(this.map)

        marker.bindPopup(
          `<strong>🔥 Fire Detection</strong><br/>` +
          `Brightness: ${fire.b || "—"}K<br/>` +
          `Confidence: ${fire.c || "—"}`
        )

        this.fireMarkers.push(marker)
      })
    },

    _calculateHeatRadius(points) {
      if (points.length < 2) return 80

      let totalNearest = 0
      for (let i = 0; i < points.length; i++) {
        let minDist = Infinity
        for (let j = 0; j < points.length; j++) {
          if (i === j) continue
          const dLat = points[i][0] - points[j][0]
          const dLng = points[i][1] - points[j][1]
          const dist = Math.sqrt(dLat * dLat + dLng * dLng)
          if (dist < minDist) minDist = dist
        }
        totalNearest += minDist
      }
      const avgNearestDeg = totalNearest / points.length

      const center = this.map.getCenter()
      const pointA = this.map.latLngToContainerPoint(center)
      const pointB = this.map.latLngToContainerPoint(
        L.latLng(center.lat + avgNearestDeg, center.lng)
      )
      const pixelsPerDeg = Math.abs(pointB.y - pointA.y)
      const halfNeighborPx = (avgNearestDeg / 2) * pixelsPerDeg

      return Math.max(40, Math.min(150, Math.round(halfNeighborPx)))
    },

    destroyed() {
      if (this.map) {
        this.fireMarkers.forEach(m => m.remove())
        this.markers.forEach(m => m.remove())
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

