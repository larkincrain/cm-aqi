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

// ============================================================================
// IDW Interpolated Heatmap (Windy-style)
// ============================================================================

// AQI color stops for smooth interpolation between bands
const AQI_STOPS = [
  { v: 0,   r: 25,  g: 135, b: 84  }, // Good green
  { v: 50,  r: 25,  g: 135, b: 84  },
  { v: 51,  r: 255, g: 193, b: 7   }, // Moderate yellow
  { v: 100, r: 255, g: 193, b: 7   },
  { v: 101, r: 253, g: 126, b: 20  }, // USG orange
  { v: 150, r: 253, g: 126, b: 20  },
  { v: 151, r: 220, g: 53,  b: 69  }, // Unhealthy red
  { v: 200, r: 220, g: 53,  b: 69  },
  { v: 201, r: 111, g: 66,  b: 193 }, // Very Unhealthy purple
  { v: 300, r: 111, g: 66,  b: 193 },
  { v: 301, r: 132, g: 32,  b: 41  }, // Hazardous dark red
  { v: 500, r: 132, g: 32,  b: 41  },
]

// Returns [r, g, b, a] for a given AQI value with smooth interpolation
function aqiColorRGBA(value, alpha) {
  if (value <= 0) return [AQI_STOPS[0].r, AQI_STOPS[0].g, AQI_STOPS[0].b, alpha]
  if (value >= 500) {
    const last = AQI_STOPS[AQI_STOPS.length - 1]
    return [last.r, last.g, last.b, alpha]
  }
  for (let i = 0; i < AQI_STOPS.length - 1; i++) {
    const a = AQI_STOPS[i], b = AQI_STOPS[i + 1]
    if (value >= a.v && value <= b.v) {
      const t = b.v === a.v ? 0 : (value - a.v) / (b.v - a.v)
      return [
        Math.round(a.r + t * (b.r - a.r)),
        Math.round(a.g + t * (b.g - a.g)),
        Math.round(a.b + t * (b.b - a.b)),
        alpha
      ]
    }
  }
  return [132, 32, 41, alpha]
}

// Spatial grid index for nearest-neighbor lookup (wider radius for full coverage)
function buildSpatialIndex(stations, cellSize) {
  const grid = {}
  stations.forEach(s => {
    const col = Math.floor(s.lat / cellSize)
    const row = Math.floor(s.lng / cellSize)
    const key = col + "," + row
    if (!grid[key]) grid[key] = []
    grid[key].push(s)
  })
  return { grid, cellSize }
}

function queryNearby(lat, lng, index, radius) {
  const cellRadius = radius || 2
  const col = Math.floor(lat / index.cellSize)
  const row = Math.floor(lng / index.cellSize)
  const results = []
  for (let dc = -cellRadius; dc <= cellRadius; dc++) {
    for (let dr = -cellRadius; dr <= cellRadius; dr++) {
      const key = (col + dc) + "," + (row + dr)
      const cell = index.grid[key]
      if (cell) {
        for (let i = 0; i < cell.length; i++) results.push(cell[i])
      }
    }
  }
  return results
}

// Chiang Mai center for distance check
const CM_LAT = 18.79, CM_LNG = 98.98, CM_RADIUS_DEG = 5.0  // ~500km

// Custom Leaflet layer for IDW canvas overlay
const IdwOverlay = L.Layer.extend({
  initialize(options) {
    L.setOptions(this, options)
    this._stations = []
    this._index = null
    this._drawTimer = null
  },

  onAdd(map) {
    this._map = map
    this._canvas = L.DomUtil.create("canvas", "idw-overlay")
    const pane = map.getPane("overlayPane")
    pane.appendChild(this._canvas)
    this._canvas.style.position = "absolute"
    this._canvas.style.pointerEvents = "none"
    this._canvas.style.opacity = "0.55"
    this._canvas.style.zIndex = "440"

    map.on("moveend", this._scheduleRedraw, this)
    map.on("resize", this._scheduleRedraw, this)
    this._reset()
  },

  onRemove(map) {
    if (this._canvas && this._canvas.parentNode) {
      this._canvas.parentNode.removeChild(this._canvas)
    }
    map.off("moveend", this._scheduleRedraw, this)
    map.off("resize", this._scheduleRedraw, this)
    if (this._drawTimer) cancelAnimationFrame(this._drawTimer)
  },

  setStations(stations) {
    this._stations = stations
    this._index = buildSpatialIndex(stations, 0.5)
    this._scheduleRedraw()
  },

  setVisible(visible) {
    if (this._canvas) this._canvas.style.display = visible ? "" : "none"
  },

  _scheduleRedraw() {
    if (this._drawTimer) cancelAnimationFrame(this._drawTimer)
    this._drawTimer = requestAnimationFrame(() => {
      this._reset()
      this._drawTimer = null
    })
  },

  _reset() {
    if (!this._map || !this._canvas) return
    const map = this._map
    const size = map.getSize()
    const topLeft = map.containerPointToLayerPoint([0, 0])

    L.DomUtil.setPosition(this._canvas, topLeft)
    this._canvas.width = size.x
    this._canvas.height = size.y
    this._draw()
  },

  _draw() {
    const map = this._map
    const canvas = this._canvas
    const ctx = canvas.getContext("2d")
    const w = canvas.width
    const h = canvas.height

    if (!w || !h || this._stations.length === 0) {
      ctx.clearRect(0, 0, w, h)
      return
    }

    // Use a smaller offscreen canvas then scale up for smooth edges
    const STEP = 6
    const sw = Math.ceil(w / STEP)
    const sh = Math.ceil(h / STEP)
    const offscreen = document.createElement("canvas")
    offscreen.width = sw
    offscreen.height = sh
    const offCtx = offscreen.getContext("2d")
    const imgData = offCtx.createImageData(sw, sh)
    const data = imgData.data
    const MAX_DIST_SQ = 5.0 * 5.0  // ~500km in degrees squared — full coverage

    // For each pixel in the small canvas
    for (let sy = 0; sy < sh; sy++) {
      for (let sx = 0; sx < sw; sx++) {
        // Map small canvas pixel to real map pixel
        const px = sx * STEP + STEP / 2
        const py = sy * STEP + STEP / 2
        const latlng = map.containerPointToLatLng([px, py])
        const lat = latlng.lat
        const lng = latlng.lng

        // Only color within ~500km of Chiang Mai
        const cmDlat = lat - CM_LAT
        const cmDlng = lng - CM_LNG
        if (cmDlat * cmDlat + cmDlng * cmDlng > CM_RADIUS_DEG * CM_RADIUS_DEG) continue

        // Query stations from spatial index (search 3 cells in each direction)
        const nearby = queryNearby(lat, lng, this._index, 3)

        let wSum = 0
        let vSum = 0
        let exactVal = null

        for (let i = 0; i < nearby.length; i++) {
          const s = nearby[i]
          const dlat = lat - s.lat
          const dlng = lng - s.lng
          const distSq = dlat * dlat + dlng * dlng

          if (distSq < 0.0001) {
            exactVal = s.aqi
            break
          }
          if (distSq > MAX_DIST_SQ) continue

          const weight = 1 / (distSq * distSq)  // 1/d^4 for sharper local influence
          wSum += weight
          vSum += weight * s.aqi
        }

        if (exactVal === null && wSum === 0) continue

        const interpolated = exactVal !== null ? exactVal : vSum / wSum
        const rgba = aqiColorRGBA(interpolated, 180)
        const idx = (sy * sw + sx) * 4
        data[idx] = rgba[0]
        data[idx + 1] = rgba[1]
        data[idx + 2] = rgba[2]
        data[idx + 3] = rgba[3]
      }
    }

    offCtx.putImageData(imgData, 0, 0)

    // Scale up with bilinear interpolation for smooth edges
    ctx.clearRect(0, 0, w, h)
    ctx.imageSmoothingEnabled = true
    ctx.imageSmoothingQuality = "high"
    ctx.drawImage(offscreen, 0, 0, sw, sh, 0, 0, w, h)
  }
})

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
      this._showHeatmap = true
      this._showFires = true
      this.idwLayer = new IdwOverlay()
      this.idwLayer.addTo(this.map)
      this._pendingMapData = null
      this._pendingFireData = null
      this._mapReady = false

      // Add toggle controls (theme-aware)
      const toggleControl = L.control({ position: "topright" })
      toggleControl.onAdd = () => {
        const div = L.DomUtil.create("div", "leaflet-bar leaflet-control map-toggle-control")
        const isDark = document.documentElement.getAttribute("data-theme") === "dark"
        div.style.padding = "8px 12px"
        div.style.borderRadius = "8px"
        div.style.fontSize = "13px"
        div.style.lineHeight = "1.8"
        div.style.boxShadow = "0 2px 6px rgba(0,0,0,0.3)"
        div.style.background = isDark ? "#1d232a" : "white"
        div.style.color = isDark ? "#a6adba" : "#1f2937"
        div.innerHTML = `
          <label style="display:block;cursor:pointer;user-select:none">
            <input type="checkbox" id="toggle-heatmap" checked style="margin-right:4px"> Heatmap
          </label>
          <label style="display:block;cursor:pointer;user-select:none">
            <input type="checkbox" id="toggle-fires" checked style="margin-right:4px"> 🔥 Fires
          </label>
        `
        L.DomEvent.disableClickPropagation(div)

        // Watch for theme changes
        const observer = new MutationObserver(() => {
          const dark = document.documentElement.getAttribute("data-theme") === "dark"
          div.style.background = dark ? "#1d232a" : "white"
          div.style.color = dark ? "#a6adba" : "#1f2937"
        })
        observer.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] })
        div._themeObserver = observer

        return div
      }
      toggleControl.addTo(this.map)

      // Wire up toggles
      setTimeout(() => {
        const heatToggle = document.getElementById("toggle-heatmap")
        const fireToggle = document.getElementById("toggle-fires")
        if (heatToggle) heatToggle.addEventListener("change", (e) => {
          this._showHeatmap = e.target.checked
          this.idwLayer.setVisible(this._showHeatmap)
        })
        if (fireToggle) fireToggle.addEventListener("change", (e) => {
          this._showFires = e.target.checked
          this.fireMarkers.forEach(m => {
            if (this._showFires) m.addTo(this.map)
            else m.remove()
          })
        })
      }, 100)

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

      // Wait for the container to have real dimensions before rendering.
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
          // Request fires now that the map is sized and ready
          this._requestFires()
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

      // Request fires whenever the map is panned/zoomed
      this.map.on("moveend", () => this._requestFires())
    },

    _processMapData(data) {
      this.markers.forEach(m => m.remove())
      this.markers = []

      // Update IDW overlay with active station data
      const idwStations = data.markers
        .filter(s => s.active && s.aqi != null)
        .map(s => ({ lat: s.lat, lng: s.lng, aqi: s.aqi }))
      this.idwLayer.setStations(idwStations)

      data.markers.forEach(station => {
        const color = station.color || "#808080"
        const isActive = station.active

        let radius, weight, opacity, fillOpacity
        if (isActive) {
          radius = 14; weight = 2; opacity = 1; fillOpacity = 0.9
        } else {
          radius = 5; weight = 1; opacity = 0.4; fillOpacity = 0.3
        }

        const marker = L.circleMarker([station.lat, station.lng], {
          radius, fillColor: color, color: "#fff", weight, opacity, fillOpacity,
        }).addTo(this.map)

        if (isActive && station.aqi != null) {
          marker.bindTooltip(String(station.aqi), {
            permanent: true, direction: "center", className: "aqi-marker-label",
          })
        }

        marker.bindPopup(
          `<a href="/sensors/${station.id}" class="font-bold hover:underline">${station.name}</a><br/>` +
          (isActive
            ? `AQI: <strong style="color:${color}">${station.aqi || "—"}</strong><br/>${station.category || "No Data"}`
            : `<em style="color:#999">Inactive</em>`)
        )

        if (isActive && station.id) {
          marker.on("click", () => { window.location.href = "/sensors/" + station.id })
        }

        this.markers.push(marker)
      })

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
        })
        if (this._showFires) marker.addTo(this.map)

        marker.bindPopup(
          `<strong>🔥 Fire Detection</strong><br/>` +
          `Brightness: ${fire.b || "—"}K<br/>` +
          `Confidence: ${fire.c || "—"}`
        )

        this.fireMarkers.push(marker)
      })
    },

    destroyed() {
      if (this.map) {
        if (this.idwLayer) this.map.removeLayer(this.idwLayer)
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
  },

  // ScrollRight: Scrolls a container to the right on mount so the most
  // recent item (last child) is visible.
  ScrollRight: {
    mounted() {
      requestAnimationFrame(() => {
        this.el.scrollLeft = this.el.scrollWidth
      })
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

