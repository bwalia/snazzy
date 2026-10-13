import { Channel, invoke } from "@tauri-apps/api/core";

interface AppInfo {
  version: string;
  platform: string;
}

interface ChatSettings {
  provider: "ollama" | "anthropic";
  model: string;
  ollamaUrl: string;
  cloudConsent: boolean;
}

interface ChatStatus {
  settings: ChatSettings;
  hasAnthropicKey: boolean;
  local: boolean;
}

type ChatEvent =
  | { type: "text"; delta: string }
  | { type: "thinking" }
  | { type: "tool"; name: string }
  | { type: "usage"; input: number; output: number }
  | { type: "needsUser"; message: string }
  | { type: "done" }
  | { type: "error"; message: string };

const SUGGESTED_ANTHROPIC = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"];

const app = document.querySelector<HTMLDivElement>("#app")!;

// The main window: chat on the left, panels on the right (as on the Mac).
app.innerHTML = `
  <main class="shell">
    <section class="chat" aria-label="Chat">
      <header class="chat-head">
        <strong>Snazzy Pro</strong>
        <span id="model" class="muted"></span>
        <span id="where" class="badge"></span>
        <span class="spacer"></span>
        <span id="tokens" class="muted small"></span>
        <button id="new" class="ghost" title="New conversation (Ctrl+N)">New</button>
        <button id="open-settings" class="ghost" title="Settings">Settings</button>
      </header>
      <div class="transcript" id="transcript" aria-live="polite">
        <div class="empty" id="empty">
          <h2>What are we making?</h2>
          <p class="muted">“Make a 6-slide deck on our Q3 results for the leadership team.”</p>
          <p class="muted">“Plan a 5-minute talk on our new onboarding, with speaker notes.”</p>
        </div>
      </div>
      <form class="composer" id="composer">
        <textarea id="prompt" rows="2" placeholder="Ask Snazzy… (Enter to send, Shift+Enter for a new line)"></textarea>
        <button type="submit" id="send">Send</button>
      </form>
    </section>
    <section class="panel" aria-label="Panels">
      <nav class="tabs" role="tablist">
        ${["Builder", "Sources & Preview", "Slides", "Recordings", "Live"]
          .map((t, i) => `<button role="tab" aria-selected="${i === 0}">${t}</button>`)
          .join("")}
      </nav>
      <div class="panel-body muted">Decks, recording and the live room arrive in the next phases.</div>
    </section>
  </main>

  <dialog id="settings">
    <form method="dialog" class="dialog">
      <h3>Settings</h3>
      <label>Assistant
        <select id="provider">
          <option value="ollama">Ollama (on this computer or your network)</option>
          <option value="anthropic">Claude (Anthropic, in the cloud)</option>
        </select>
      </label>
      <label id="ollama-row">Ollama address
        <input id="ollama-url" type="url" placeholder="http://localhost:11434" />
      </label>
      <label id="key-row">Anthropic API key
        <span class="row">
          <input id="anthropic-key" type="password" autocomplete="off" placeholder="Saved in your system's credential store" />
          <button type="button" id="save-key">Save Key</button>
        </span>
        <span class="muted small" id="key-state"></span>
      </label>
      <label>Model
        <span class="row">
          <input id="model-input" list="models" placeholder="e.g. qwen3-coder:30b" />
          <button type="button" id="refresh-models">List Models</button>
        </span>
        <datalist id="models"></datalist>
        <span class="muted small" id="models-state"></span>
      </label>
      <div class="actions">
        <button value="cancel" class="ghost">Cancel</button>
        <button id="save-settings" value="save">Save</button>
      </div>
    </form>
  </dialog>

  <dialog id="consent">
    <form method="dialog" class="dialog">
      <h3>Send chats to Anthropic?</h3>
      <p>Your messages and the assistant's replies will go from this computer to Anthropic, using your own API key.
      Ollama keeps everything on this computer or your network.</p>
      <div class="actions">
        <button value="no" class="ghost">Not Now</button>
        <button value="yes">Send to Anthropic</button>
      </div>
    </form>
  </dialog>`;

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const transcript = $<HTMLDivElement>("transcript");
const prompt = $<HTMLTextAreaElement>("prompt");
const send = $<HTMLButtonElement>("send");
const settingsDialog = $<HTMLDialogElement>("settings");
const consentDialog = $<HTMLDialogElement>("consent");

let status: ChatStatus | null = null;
let running = false;
let tokens = { input: 0, output: 0 };

function show(s: ChatStatus) {
  status = s;
  $("model").textContent = s.settings.model || "No model chosen";
  const where = $("where");
  where.textContent = s.local ? "Local" : "Cloud";
  where.className = `badge ${s.local ? "local" : "cloud"}`;
  where.title = s.local ? "Messages stay on this computer or your network" : "Messages go to Anthropic";
}

function bubble(role: "user" | "assistant" | "note", text = ""): HTMLDivElement {
  $("empty")?.remove();
  const div = document.createElement("div");
  div.className = `msg ${role}`;
  div.textContent = text;
  transcript.appendChild(div);
  transcript.scrollTop = transcript.scrollHeight;
  return div;
}

function setRunning(on: boolean) {
  running = on;
  send.textContent = on ? "Stop" : "Send";
  send.classList.toggle("stop", on);
}

async function ask(): Promise<boolean> {
  consentDialog.showModal();
  const answer = await new Promise<string>((resolve) =>
    consentDialog.addEventListener("close", () => resolve(consentDialog.returnValue), { once: true }),
  );
  if (answer !== "yes") return false;
  show(await invoke<ChatStatus>("agree_to_cloud"));
  return true;
}

async function submit() {
  if (running) {
    await invoke("stop_chat");
    setRunning(false);
    return;
  }
  const text = prompt.value.trim();
  if (!text || !status) return;
  if (!status.settings.model) {
    openSettings();
    return;
  }
  if (!status.local && !status.settings.cloudConsent && !(await ask())) return;

  prompt.value = "";
  bubble("user", text);
  const reply = bubble("assistant");
  reply.classList.add("pending");
  setRunning(true);

  const events = new Channel<ChatEvent>();
  events.onmessage = (e) => {
    switch (e.type) {
      case "text":
        reply.classList.remove("pending");
        reply.textContent += e.delta;
        transcript.scrollTop = transcript.scrollHeight;
        break;
      case "thinking":
        reply.dataset.thinking = "Thinking…";
        break;
      case "tool":
        bubble("note", `Using ${e.name}…`);
        break;
      case "usage":
        tokens = { input: tokens.input + e.input, output: tokens.output + e.output };
        $("tokens").textContent = `${tokens.input} in · ${tokens.output} out`;
        break;
      case "needsUser":
        bubble("note", e.message);
        break;
      case "error":
        bubble("note", e.message).classList.add("error");
        break;
      case "done":
        reply.classList.remove("pending");
        delete reply.dataset.thinking;
        if (!reply.textContent) reply.remove();
        setRunning(false);
        break;
    }
  };
  try {
    await invoke("send_chat", { text, events });
  } catch (err) {
    reply.remove();
    bubble("note", String(err)).classList.add("error");
    setRunning(false);
  }
}

$("composer").addEventListener("submit", (e) => {
  e.preventDefault();
  void submit();
});
prompt.addEventListener("keydown", (e) => {
  if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
    e.preventDefault();
    void submit();
  }
});

async function newConversation() {
  await invoke("new_conversation");
  setRunning(false);
  tokens = { input: 0, output: 0 };
  $("tokens").textContent = "";
  transcript.innerHTML = `<div class="empty" id="empty"><h2>What are we making?</h2></div>`;
  prompt.focus();
}
$("new").addEventListener("click", () => void newConversation());
document.addEventListener("keydown", (e) => {
  if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "n") {
    e.preventDefault();
    void newConversation();
  }
});

// Settings

function providerRows() {
  const anthropic = $<HTMLSelectElement>("provider").value === "anthropic";
  $("ollama-row").hidden = anthropic;
  $("key-row").hidden = !anthropic;
}

function openSettings() {
  if (!status) return;
  $<HTMLSelectElement>("provider").value = status.settings.provider;
  $<HTMLInputElement>("ollama-url").value = status.settings.ollamaUrl;
  $<HTMLInputElement>("model-input").value = status.settings.model;
  $<HTMLInputElement>("anthropic-key").value = "";
  $("key-state").textContent = status.hasAnthropicKey ? "A key is saved." : "No key saved.";
  $("models-state").textContent = "";
  providerRows();
  settingsDialog.showModal();
}

function draft(): ChatSettings {
  const provider = $<HTMLSelectElement>("provider").value as ChatSettings["provider"];
  return {
    provider,
    model: $<HTMLInputElement>("model-input").value.trim(),
    ollamaUrl: $<HTMLInputElement>("ollama-url").value.trim() || "http://localhost:11434",
    cloudConsent: status?.settings.cloudConsent ?? false,
  };
}

$("open-settings").addEventListener("click", openSettings);
$("provider").addEventListener("change", () => {
  providerRows();
  if ($<HTMLSelectElement>("provider").value === "anthropic" && !$<HTMLInputElement>("model-input").value) {
    $<HTMLInputElement>("model-input").value = SUGGESTED_ANTHROPIC[0];
  }
});
$("save-key").addEventListener("click", async () => {
  const input = $<HTMLInputElement>("anthropic-key");
  try {
    show(await invoke<ChatStatus>("set_anthropic_key", { key: input.value }));
    input.value = "";
    $("key-state").textContent = status?.hasAnthropicKey ? "Key saved in your credential store." : "Key removed.";
  } catch (err) {
    $("key-state").textContent = String(err);
  }
});
$("refresh-models").addEventListener("click", async () => {
  $("models-state").textContent = "Listing…";
  try {
    // List with what's in the form, without saving consent.
    show(await invoke<ChatStatus>("set_chat_settings", { settings: draft() }));
    const models = await invoke<string[]>("list_models");
    const options = models.length ? models : SUGGESTED_ANTHROPIC;
    $("models").innerHTML = options.map((m) => `<option value="${m.replace(/"/g, "&quot;")}"></option>`).join("");
    $("models-state").textContent = `${models.length} model${models.length === 1 ? "" : "s"} found.`;
    if (!$<HTMLInputElement>("model-input").value && options[0]) $<HTMLInputElement>("model-input").value = options[0];
  } catch (err) {
    $("models-state").textContent = String(err);
  }
});
settingsDialog.addEventListener("close", async () => {
  if (settingsDialog.returnValue !== "save") return;
  show(await invoke<ChatStatus>("set_chat_settings", { settings: draft() }));
});

// Start

invoke<AppInfo>("app_info")
  .then((info) => (document.title = `Snazzy Pro ${info.version}`))
  .catch(() => undefined);
invoke<ChatStatus>("chat_status")
  .then((s) => {
    show(s);
    if (!s.settings.model) openSettings();
  })
  .catch(() => ($("model").textContent = "Preview (no app backend)"));
prompt.focus();
