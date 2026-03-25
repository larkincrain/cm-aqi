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

const Hooks = {
  // AqiChart: Renders a Chart.js line chart showing AQI history for a station.
  // Connected to elements with phx-hook="AqiChart" in the dashboard template.
  AqiChart: {
    // mounted() is called when the element is first added to the DOM.
    mounted() {
      const canvas = this.el.querySelector("canvas")
      if (!canvas || typeof Chart === "undefined") return

      // Create a simple line chart with placeholder data.
      // In a full implementation, this would fetch historical data from the server.
      this.chart = new Chart(canvas.getContext("2d"), {
        type: "line",
        data: {
          labels: [],
          datasets: [{
            label: "AQI",
            data: [],
            borderColor: "#3b82f6",
            backgroundColor: "rgba(59, 130, 246, 0.1)",
            fill: true,
            tension: 0.3,
            pointRadius: 1,
          }]
        },
        options: {
          responsive: true,
          maintainAspectRatio: false,
          plugins: {
            legend: { display: false },
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

      // Request historical data from the server via a LiveView event.
      // The server will push data back via push_event.
      this.handleEvent("chart_data:" + this.el.dataset.stationId, (data) => {
        this.chart.data.labels = data.labels
        this.chart.data.datasets[0].data = data.values
        this.chart.update()
      })
    },

    // destroyed() is called when the element is removed from the DOM.
    // We clean up the Chart.js instance to prevent memory leaks.
    destroyed() {
      if (this.chart) {
        this.chart.destroy()
      }
    }
  }
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ...Hooks},
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

