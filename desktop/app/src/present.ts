// The Present window: the deck alone, on any display. Slides change from here
// (arrow keys, clicks in the deck), from the main window or, later, the remote;
// the app keeps every window on the same slide.
import { listen } from "@tauri-apps/api/event";
import { api, deckFrame, showSlide, type Presenting } from "./api";
import { html } from "./ui";

export function startPresentWindow(root: HTMLElement) {
  document.body.classList.add("present-view");
  const frame = deckFrame("present-frame");
  const hint = html(`<div class="present-hint">← → change slides · F full screen · Esc leaves full screen</div>`);
  root.replaceChildren(frame, hint);

  let state: Presenting | null = null;
  let count = 0;
  let current = -1;

  function apply(p: Presenting | null) {
    if (!p) {
      root.replaceChildren(html(`<p class="present-empty">Nothing to present. Open a deck in Snazzy Pro.</p>`));
      return;
    }
    const newDeck = !state || state.url !== p.url;
    state = p;
    document.title = `${p.title} · Snazzy Pro`;
    if (newDeck) {
      current = -1;
      frame.src = `${p.url}#${p.index}`;
    } else if (p.index !== current) {
      showSlide(frame, p.index);
    }
  }

  window.addEventListener("message", (e) => {
    if (e.source !== frame.contentWindow || !e.data || typeof e.data !== "object") return;
    const m = e.data as { snazzy?: string; index?: number; slides?: unknown[]; url?: string };
    if (m.snazzy === "deck" && typeof m.index === "number") {
      if (m.slides) count = m.slides.length;
      if (m.index >= 0 && m.index !== current) {
        current = m.index;
        // A slide changed inside the deck (its own keys): tell the other windows.
        if (state && m.index !== state.index) void api.presentGo(m.index);
      }
    } else if (m.snazzy === "open" && m.url) {
      void api.openLink(m.url);
    } else if (m.snazzy === "key") {
      const key = (m as { key?: string }).key;
      if (key === "Escape") void api.presentFullscreen(false);
      else if (key === "f" || key === "F") void api.presentFullscreen();
    }
  });

  // Keys while the window itself (not the deck) has focus.
  document.addEventListener("keydown", (e) => {
    if (!state) return;
    const go = (i: number) => void api.presentGo(Math.max(0, count ? Math.min(i, count - 1) : i));
    switch (e.key) {
      case "ArrowRight":
      case "ArrowDown":
      case "PageDown":
      case " ":
        go(current + 1);
        break;
      case "ArrowLeft":
      case "ArrowUp":
      case "PageUp":
        go(current - 1);
        break;
      case "f":
      case "F":
        void api.presentFullscreen();
        break;
      case "Escape":
        void api.presentFullscreen(false);
        break;
      default:
        return;
    }
    e.preventDefault();
  });
  frame.addEventListener("load", () => frame.focus());

  // The hint fades once the mouse rests.
  let idle = 0;
  const wake = () => {
    hint.classList.add("show");
    document.body.classList.remove("idle");
    window.clearTimeout(idle);
    idle = window.setTimeout(() => {
      hint.classList.remove("show");
      document.body.classList.add("idle");
    }, 2500);
  };
  document.addEventListener("mousemove", wake);
  wake();

  void listen<Presenting | null>("present", (e) => apply(e.payload));
  void api.presentState().then(apply);
}
