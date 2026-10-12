import { invoke } from "@tauri-apps/api/core";

interface AppInfo {
  version: string;
  platform: string;
}

const app = document.querySelector<HTMLDivElement>("#app")!;

// The main window: chat on the left, panels on the right (as on the Mac).
app.innerHTML = `
  <main class="shell">
    <section class="chat" aria-label="Chat">
      <header class="chat-head"><strong>Snazzy Pro</strong><span id="info" class="muted"></span></header>
      <div class="transcript" id="transcript">
        <h2>What are we making?</h2>
        <p class="muted">“Make a 6-slide deck on our Q3 results for the leadership team.”</p>
      </div>
      <form class="composer" id="composer">
        <textarea id="prompt" rows="2" placeholder="Ask Snazzy… (Enter to send, Shift+Enter for a new line)"></textarea>
        <button type="submit">Send</button>
      </form>
    </section>
    <section class="panel" aria-label="Panels">
      <nav class="tabs" role="tablist">
        ${["Builder", "Sources & Preview", "Slides", "Recordings", "Live"]
          .map((t, i) => `<button role="tab" aria-selected="${i === 0}">${t}</button>`)
          .join("")}
      </nav>
      <div class="panel-body muted">Coming in the next phases.</div>
    </section>
  </main>`;

invoke<AppInfo>("app_info")
  .then((info) => {
    document.querySelector("#info")!.textContent = `${info.version} · ${info.platform}`;
  })
  .catch(() => {
    document.querySelector("#info")!.textContent = "preview";
  });
