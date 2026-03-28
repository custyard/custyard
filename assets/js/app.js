// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"

let Hooks = {}

Hooks.ScrollIntoView = {
  mounted() {
    this.el.scrollIntoView({behavior: "smooth", block: "start"})
  }
}

Hooks.ScrollBottom = {
  mounted() {
    // Always scroll to bottom on initial mount
    this.scrollToBottom()
  },
  updated() {
    // Only auto-scroll if user is near the bottom (within 100px)
    // This respects user intent when they've scrolled up to read older messages
    if (this.isNearBottom()) {
      this.scrollToBottom()
    }
  },
  isNearBottom() {
    const threshold = 100 // pixels from bottom
    return (this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight) < threshold
  },
  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight
  }
}

// Reset textarea value after form submit
// Ensures textarea is cleared even when LiveView DOM diffing might not update inner content
Hooks.ResetOnSubmit = {
  mounted() {
    const form = this.el.closest("form")
    if (form) {
      form.addEventListener("submit", () => {
        // Clear on next tick after form data is collected
        setTimeout(() => {
          this.el.value = ""
        }, 0)
      })
    }
  }
}

// Submit form on Ctrl+Enter or Cmd+Enter
// Useful for quick message sending in operator interfaces
Hooks.CtrlEnterSubmit = {
  mounted() {
    this.el.addEventListener("keydown", (e) => {
      if ((e.ctrlKey || e.metaKey) && e.key === "Enter") {
        e.preventDefault()
        const form = this.el.closest("form")
        if (form) {
          // Trigger form submission through LiveView
          form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }))
        }
      }
    })
  }
}

// Auto-dismiss flash messages after a timeout
// Used for info/success flashes that don't need user acknowledgment
Hooks.AutoDismiss = {
  mounted() {
    const timeout = parseInt(this.el.dataset.dismissTimeout || "5000")
    this.timer = setTimeout(() => {
      // Fade out then hide
      this.el.style.transition = "opacity 200ms ease-out"
      this.el.style.opacity = "0"
      setTimeout(() => {
        this.el.style.display = "none"
        // Clear the flash from LiveView state
        this.pushEvent("lv:clear-flash", {key: this.el.dataset.flashKind || "info"})
      }, 200)
    }, timeout)
  },
  destroyed() {
    if (this.timer) clearTimeout(this.timer)
  }
}

Hooks.CopyToClipboard = {
  mounted() {
    this.handler = () => {
      const text = this.el.dataset.clipboardText
      if (text && navigator.clipboard) {
        navigator.clipboard.writeText(text).then(() => {
          const original = this.el.textContent
          this.el.textContent = "Copied!"
          setTimeout(() => { this.el.textContent = original }, 1500)
        }).catch(err => {
          console.error("Failed to copy text: ", err)
        })
      }
    }
    this.el.addEventListener("click", this.handler)
  },
  destroyed() {
    this.el.removeEventListener("click", this.handler)
  }
}

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks
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
