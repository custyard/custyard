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

// Staff composer textarea. Ctrl+Enter or Cmd+Enter submits the form, and the
// box grows with what is typed until it reaches 40% of the viewport or the
// room the page chrome leaves, then scrolls. The height is reapplied after
// every server patch, which drops inline styles.
Hooks.ComposerInput = {
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
    this.el.addEventListener("input", () => this.fit())
    this.fit()
  },
  updated() {
    this.fit()
  },
  fit() {
    const el = this.el
    // The box shares a column with the conversation. Leave room for the page
    // chrome (about 320px, 470px on a phone, where the header wraps) and some
    // 150px of conversation. The cap never drops below 96px, about three lines.
    const room = window.innerHeight - (window.innerWidth < 768 ? 620 : 480)
    const limit = Math.max(96, Math.min(Math.round(window.innerHeight * 0.4), room))
    el.style.height = "auto"
    const border = el.offsetHeight - el.clientHeight
    const wanted = el.scrollHeight + border
    el.style.height = Math.min(wanted, limit) + "px"
    el.style.overflowY = wanted > limit ? "auto" : "hidden"
  }
}

// Single-key shortcuts must never fire while the staff member is typing or
// holding a modifier (Ctrl+K, Cmd+J and friends belong to the browser).
const shortcutBlocked = (e) => {
  if (e.defaultPrevented || e.ctrlKey || e.metaKey || e.altKey || e.shiftKey) return true
  const t = e.target
  if (!(t instanceof Element)) return false
  return t.isContentEditable || t.closest("input, textarea, select, [contenteditable]") !== null
}

// Attention queue: j / k (or the arrow keys) move the selection through the
// rows and o opens it. The selection is the focused row link, so Enter opens
// it natively, Tab carries on from it and screen readers announce the row.
// data-select names the row to start from (the conversation just left).
// The hook sits on the element around the list, which stays when the list
// empties and the note marked data-list-empty takes its place.
Hooks.QueueKeys = {
  mounted() {
    this.onKey = (e) => {
      // An open snooze menu keeps the keys: moving the selection would leave
      // it open on a row that is no longer selected.
      if (shortcutBlocked(e) || this.el.querySelector("[role=menu]")) return
      const key = e.key.length === 1 ? e.key.toLowerCase() : e.key
      const links = Array.from(this.el.querySelectorAll("[data-row-link]"))
      if (links.length === 0) return
      const row = document.activeElement?.closest?.("li")
      const current = links.findIndex(link => link.closest("li") === row)

      if (key === "j" || key === "ArrowDown") {
        this.select(links[Math.min(current + 1, links.length - 1)])
      } else if (key === "k" || key === "ArrowUp") {
        this.select(links[Math.max(current - 1, 0)])
      } else if (key === "o" && current >= 0) {
        links[current].click()
      } else {
        return
      }
      e.preventDefault()
    }
    window.addEventListener("keydown", this.onKey)

    const start = this.el.dataset.select
    const link = start && this.el.querySelector(`#queue-row-${CSS.escape(start)} [data-row-link]`)
    if (link) this.select(link)
  },
  // A row can leave the list while the focus is on it or on one of its
  // buttons (dismissed, snoozed, a task marked done). The focus would fall to
  // the page and the next j would start again from the top, so it moves to
  // the row that took its place, or to the note that the list is empty when
  // it was the last one.
  beforeUpdate() {
    const list = this.el.querySelector(":scope > ul")
    const rows = list ? Array.from(list.children) : []
    const index = rows.findIndex(row => row.contains(document.activeElement))
    this.focusIndex = index >= 0 ? index : null
  },
  updated() {
    if (this.focusIndex === null || this.el.contains(document.activeElement)) return
    const links = Array.from(this.el.querySelectorAll("[data-row-link]"))
    if (links.length > 0) {
      this.select(links[Math.min(this.focusIndex, links.length - 1)])
    } else {
      this.el.querySelector("[data-list-empty]")?.focus({preventScroll: true})
    }
    this.focusIndex = null
  },
  destroyed() {
    window.removeEventListener("keydown", this.onKey)
  },
  select(link) {
    link.focus({preventScroll: true})
    link.scrollIntoView({block: "nearest"})
  }
}

// Clicks the descendant whose data-shortcut matches the pressed key, e.g.
// <a data-shortcut="j"> in the conversation header (j next, k previous,
// u back to the queue).
Hooks.Shortcuts = {
  mounted() {
    this.onKey = (e) => {
      // A held key repeats: j would open, and so activate, every conversation
      // on the way.
      if (e.repeat || shortcutBlocked(e) || e.key.length !== 1) return
      const target = this.el.querySelector(`[data-shortcut="${CSS.escape(e.key.toLowerCase())}"]`)
      if (!target) return
      e.preventDefault()
      target.click()
    }
    window.addEventListener("keydown", this.onKey)
  },
  destroyed() {
    window.removeEventListener("keydown", this.onKey)
  }
}

// Auto-dismiss flash messages after a timeout (configurable via
// data-dismiss-timeout, in milliseconds). Elements that are hidden at mount
// (e.g. the client/server connection-error flashes toggled by
// phx-disconnected/phx-connected) are left alone.
Hooks.AutoDismiss = {
  mounted() {
    if (this.el.hasAttribute("hidden")) return
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
const socketPath = window.location.pathname.startsWith("/admin") ? "/admin/live" :
  window.location.pathname.startsWith("/app") ? "/app/live" : "/live"
let liveSocket = new LiveSocket(socketPath, Socket, {
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
