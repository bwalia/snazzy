// Voice Notes (src-tauri/src/voice.rs, docs/specs/voice-notes.md): record while
// you talk, mark the good ideas, keep the audio, and turn it into text with a
// transcription server you run (whisper.cpp or similar). Same notes as the Mac.
import { invoke } from "@tauri-apps/api/core";
import { attempt, confirmDialog, esc, toast } from "./ui";

interface Segment {
  start: number;
  end: number;
  text: string;
}

interface Note {
  id: string;
  title: string;
  created_at: string;
  duration: number;
  audio?: string;
  transcript: string;
  segments: Segment[];
  marks: { at: number; label: string }[];
  tags: string[];
  device: string;
  transcribed_by: string;
  displayTitle: string;
  paragraphs: Segment[];
  edited: boolean;
  markdown: string;
}

interface VoiceSettings {
  server: string;
  model: string;
  remoteOk: boolean;
}

interface VoiceStatus {
  settings: VoiceSettings;
  local: boolean;
}

const ASKS = [
  {
    label: "Make a Deck",
    prompt:
      "Make a short slide deck from the ideas in this voice note of mine. Keep my ideas and wording where you can, group them into a few clear slides, and put what I said in the speaker notes.",
  },
  {
    label: "Summarise",
    prompt: "Summarise this voice note of mine: a one-line gist, then the main points as bullets. Keep the ideas I marked.",
  },
  {
    label: "List Action Points",
    prompt: "List the action points and decisions in this voice note of mine, as a checklist with who/when where I said it.",
  },
];

/** `m:ss` or `h:mm:ss`. */
export function clock(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  const pad = (n: number) => String(n).padStart(2, "0");
  return s >= 3600 ? `${Math.floor(s / 3600)}:${pad(Math.floor(s / 60) % 60)}:${pad(s % 60)}` : `${Math.floor(s / 60)}:${pad(s % 60)}`;
}

/** Base64 of a recording, in pieces (a long one would overflow the call stack). */
function base64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}

/** The recorder's best format here (Opus in WebM on Windows, WebM or Ogg on Linux). */
function recorderType(): string {
  for (const t of ["audio/webm;codecs=opus", "audio/ogg;codecs=opus", "audio/webm", "audio/ogg", "audio/mp4"]) {
    if (typeof MediaRecorder !== "undefined" && MediaRecorder.isTypeSupported(t)) return t;
  }
  return "";
}

export function mountVoiceNotes(root: HTMLElement, askChat: (text: string) => void) {
  root.innerHTML = `
    <div class="notes">
      <aside class="notes-side">
        <div class="notes-record">
          <button id="vn-record" class="record">● Record</button>
          <button id="vn-mark" class="ghost" hidden title="Mark this moment as an idea (Ctrl+M)">★</button>
        </div>
        <div id="vn-live" class="notes-live" hidden>
          <span id="vn-time">0:00</span>
          <meter id="vn-level" min="0" max="1" value="0"></meter>
          <span id="vn-marks" class="muted small"></span>
        </div>
        <input id="vn-search" type="search" placeholder="Search notes" />
        <ul id="vn-list" class="notes-list"></ul>
        <div class="notes-foot">
          <button id="vn-settings" class="ghost small">Settings</button>
          <button id="vn-folder" class="ghost small">Show Folder</button>
        </div>
      </aside>
      <section id="vn-detail" class="notes-detail"></section>
    </div>
    <dialog id="vn-settings-dialog">
      <form method="dialog" class="dialog">
        <h3>Turning speech into text</h3>
        <p class="muted small">Windows and Linux don't come with speech recognition Snazzy Pro can use, so the words come from a
        transcription server you run, such as whisper.cpp's server (<code>whisper-server -m ggml-base.en.bin --port 8080</code>,
        then <code>http://localhost:8080/inference</code>) or any server with an OpenAI-style
        <code>/v1/audio/transcriptions</code>. Leave it empty to keep recordings only.</p>
        <label>Server address<input id="vn-server" placeholder="http://localhost:8080/inference" autocomplete="off" /></label>
        <label>Model (if the server asks for one)<input id="vn-model" placeholder="whisper-1" autocomplete="off" /></label>
        <label class="check" id="vn-remote-row"><input id="vn-remote" type="checkbox" />
          This server is mine (recordings will be sent to it)</label>
        <div class="actions">
          <button value="cancel" class="ghost">Cancel</button>
          <button value="save">Save</button>
        </div>
      </form>
    </dialog>`;

  const $ = <T extends HTMLElement>(id: string) => root.querySelector<T>(`#${id}`)!;
  const list = $<HTMLUListElement>("vn-list");
  const detail = $<HTMLElement>("vn-detail");
  let notes: Note[] = [];
  let selected: string | null = null;
  let status: VoiceStatus | null = null;
  const transcribing = new Set<string>();

  // MARK: The list

  async function load() {
    const query = $<HTMLInputElement>("vn-search").value;
    notes = (await attempt(() => invoke<Note[]>("voice_notes", { query }))) ?? [];
    list.innerHTML = notes.length
      ? notes
          .map(
            (n) => `
        <li><button data-id="${esc(n.id)}" class="${n.id === selected ? "on" : ""}">
          <strong>${esc(n.displayTitle)}</strong>
          <span class="muted small">${esc(new Date(n.created_at).toLocaleString())}${n.duration > 0 ? ` · ${clock(n.duration)}` : ""}${n.marks.length ? ` · ★ ${n.marks.length}` : ""}${transcribing.has(n.id) ? " · turning into text…" : ""}</span>
        </button></li>`,
          )
          .join("")
      : `<li class="muted small">${query ? "No notes match." : "No voice notes yet. Press Record and talk."}</li>`;
    if (selected && !notes.some((n) => n.id === selected)) selected = null;
    render();
  }

  list.addEventListener("click", (e) => {
    const id = (e.target as HTMLElement).closest<HTMLElement>("[data-id]")?.dataset.id;
    if (!id) return;
    selected = id;
    list.querySelectorAll("button").forEach((b) => b.classList.toggle("on", b.dataset.id === id));
    render();
  });
  $("vn-search").addEventListener("input", () => void load());

  // MARK: One note

  let audioURL = "";

  async function render() {
    if (recorder) {
      detail.innerHTML = `<div class="empty-state"><h2>Recording…</h2><p class="muted">Talk freely. Press ★ (Ctrl+M) when you say something worth keeping.
        ${status?.settings.server ? "The words appear when you stop." : "Add a transcription server in Settings to get the words too."}</p></div>`;
      return;
    }
    const n = notes.find((x) => x.id === selected);
    if (!n) {
      detail.innerHTML = `<div class="empty-state"><h2>Talk it through</h2><p class="muted">Record a thought, a brainstorm or a meeting.
        Mark the good ideas as you go, then make a deck from them.</p></div>`;
      return;
    }
    const showText = n.segments.length === 0 || n.edited;
    detail.innerHTML = `
      <input id="vn-title" class="note-title" value="${esc(n.title)}" placeholder="${esc(n.displayTitle)}" />
      <p class="muted small">${esc(new Date(n.created_at).toLocaleString())} · ${esc(n.device)}${n.transcribed_by === "whisper-server" ? " · text from your transcription server" : ""}</p>
      ${n.audio ? `<audio id="vn-audio" controls preload="metadata"></audio>` : ""}
      ${n.marks.length ? `<div class="marks">${n.marks.map((m) => `<button class="ghost small" data-at="${m.at}">★ ${clock(m.at)} ${esc(m.label)}</button>`).join("")}</div>` : ""}
      <div class="note-text">
        ${
          showText
            ? `<textarea id="vn-text" rows="12" placeholder="${transcribing.has(n.id) ? "Turning the recording into text…" : "No words yet. Transcribe the recording, or type your notes here."}">${esc(n.transcript)}</textarea>`
            : n.paragraphs.map((p) => `<p><button class="link small" data-at="${p.start}">${clock(p.start)}</button> ${esc(p.text)}</p>`).join("")
        }
      </div>
      <label class="small">Tags <input id="vn-tags" value="${esc(n.tags.join(", "))}" placeholder="Separated by commas" /></label>
      <div class="actions left">
        ${ASKS.map((a, i) => `<button class="ghost" data-ask="${i}" ${n.transcript ? "" : "disabled"}>${a.label}</button>`).join("")}
        <span class="spacer"></span>
        ${showText ? "" : `<button class="ghost" id="vn-edit">Edit Text</button>`}
        ${n.audio ? `<button class="ghost" id="vn-transcribe" ${transcribing.has(n.id) ? "disabled" : ""}>Transcribe${n.transcript ? " Again" : ""}</button>` : ""}
        <button class="ghost" id="vn-copy">Copy</button>
        <button class="ghost" id="vn-export">Export</button>
        <button class="ghost danger-text" id="vn-delete">Delete</button>
      </div>`;

    if (audioURL) URL.revokeObjectURL(audioURL);
    audioURL = "";
    const player = detail.querySelector<HTMLAudioElement>("#vn-audio");
    if (player) {
      const a = await attempt(() => invoke<{ data: string; mime: string }>("voice_note_audio", { id: n.id }));
      if (a) {
        const bytes = Uint8Array.from(atob(a.data), (c) => c.charCodeAt(0));
        audioURL = URL.createObjectURL(new Blob([bytes], { type: a.mime }));
        player.src = audioURL;
      }
    }
    detail.querySelectorAll<HTMLElement>("[data-at]").forEach((b) =>
      b.addEventListener("click", () => {
        if (!player) return;
        player.currentTime = Math.max(0, Number(b.dataset.at) - (b.closest(".marks") ? 4 : 0));
        void player.play();
      }),
    );
    const save = async (fields: Record<string, unknown>) => {
      await attempt(() => invoke<Note>("update_voice_note", { id: n.id, ...fields }));
      await load();
    };
    detail.querySelector("#vn-title")?.addEventListener("change", (e) => void save({ title: (e.target as HTMLInputElement).value }));
    detail.querySelector("#vn-text")?.addEventListener("change", (e) => void save({ transcript: (e.target as HTMLTextAreaElement).value }));
    detail.querySelector("#vn-tags")?.addEventListener("change", (e) =>
      void save({ tags: (e.target as HTMLInputElement).value.split(",") }),
    );
    detail.querySelector("#vn-edit")?.addEventListener("click", () => {
      const box = detail.querySelector(".note-text")!;
      box.innerHTML = `<textarea id="vn-text" rows="12">${esc(n.transcript)}</textarea>`;
      box.querySelector("#vn-text")!.addEventListener("change", (e) => void save({ transcript: (e.target as HTMLTextAreaElement).value }));
    });
    detail.querySelector("#vn-transcribe")?.addEventListener("click", () => void transcribe(n.id, true));
    detail.querySelector("#vn-copy")?.addEventListener("click", async () => {
      await navigator.clipboard.writeText(n.markdown);
      toast("Copied as Markdown.");
    });
    detail.querySelector("#vn-export")?.addEventListener("click", async () => {
      const path = await attempt(() => invoke<string>("export_voice_note", { id: n.id }));
      if (path) toast(`Saved ${path}`);
    });
    detail.querySelector("#vn-delete")?.addEventListener("click", async () => {
      if (!(await confirmDialog("Delete this voice note?", "Its recording and text are deleted from this computer.", "Delete", true))) return;
      await attempt(() => invoke("delete_voice_note", { id: n.id }));
      selected = null;
      await load();
    });
    detail.querySelectorAll<HTMLElement>("[data-ask]").forEach((b) =>
      b.addEventListener("click", () => {
        const ask = ASKS[Number(b.dataset.ask)];
        askChat(`${ask.prompt}\n\n<voice_note>\n${n.markdown}</voice_note>`);
      }),
    );
  }

  async function transcribe(id: string, asked: boolean) {
    if (!status?.settings.server) {
      if (asked) openSettings();
      return;
    }
    transcribing.add(id);
    await load();
    try {
      await invoke<Note>("transcribe_voice_note", { id });
    } catch (err) {
      toast(String(err), "error");
    }
    transcribing.delete(id);
    await load();
  }

  // MARK: Recording

  let recorder: MediaRecorder | null = null;
  let stream: MediaStream | null = null;
  let chunks: Blob[] = [];
  let startedAt = 0;
  let marks: number[] = [];
  let ticker = 0;
  let audioContext: AudioContext | null = null;

  async function start() {
    const type = recorderType();
    try {
      stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true } });
    } catch (err) {
      toast(`The microphone isn't available: ${String(err)}. Check your system's privacy settings for the microphone.`, "error");
      return;
    }
    chunks = [];
    marks = [];
    recorder = new MediaRecorder(stream, type ? { mimeType: type } : undefined);
    recorder.ondataavailable = (e) => e.data.size && chunks.push(e.data);
    recorder.onstop = () => void finish();
    recorder.start(1000);
    startedAt = performance.now();
    // The level meter.
    audioContext = new AudioContext();
    const analyser = audioContext.createAnalyser();
    audioContext.createMediaStreamSource(stream).connect(analyser);
    const samples = new Float32Array(analyser.fftSize);
    ticker = window.setInterval(() => {
      analyser.getFloatTimeDomainData(samples);
      const rms = Math.sqrt(samples.reduce((s, v) => s + v * v, 0) / samples.length);
      $<HTMLMeterElement>("vn-level").value = Math.min(Math.max((20 * Math.log10(Math.max(rms, 1e-6)) + 50) / 50, 0), 1);
      $("vn-time").textContent = clock((performance.now() - startedAt) / 1000);
    }, 100);
    $("vn-record").textContent = "■ Stop";
    $("vn-record").classList.add("on");
    $("vn-mark").hidden = false;
    $("vn-live").hidden = false;
    $("vn-marks").textContent = "";
    void render();
  }

  function stop() {
    if (recorder?.state === "recording") recorder.stop();
  }

  function mark() {
    if (!recorder) return;
    marks.push((performance.now() - startedAt) / 1000);
    $("vn-marks").textContent = `★ ${marks.length}`;
  }

  async function finish() {
    const duration = (performance.now() - startedAt) / 1000;
    const mime = recorder?.mimeType || recorderType() || "audio/webm";
    window.clearInterval(ticker);
    stream?.getTracks().forEach((t) => t.stop());
    void audioContext?.close();
    recorder = null;
    stream = null;
    audioContext = null;
    $("vn-record").textContent = "● Record";
    $("vn-record").classList.remove("on");
    $("vn-mark").hidden = true;
    $("vn-live").hidden = true;
    const bytes = new Uint8Array(await new Blob(chunks, { type: mime }).arrayBuffer());
    chunks = [];
    const note = await attempt(() =>
      invoke<Note>("save_voice_recording", { audio: base64(bytes), mime, duration, marks, language: navigator.language }),
    );
    if (!note) return void render();
    selected = note.id;
    await load();
    void transcribe(note.id, false);
  }

  $("vn-record").addEventListener("click", () => (recorder ? stop() : void start()));
  $("vn-mark").addEventListener("click", mark);
  document.addEventListener("keydown", (e) => {
    if (recorder && (e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "m") {
      e.preventDefault();
      mark();
    }
  });

  // MARK: Settings

  const dialog = $<HTMLDialogElement>("vn-settings-dialog");
  function remoteRow() {
    const server = $<HTMLInputElement>("vn-server").value.trim();
    const local = /^https?:\/\/(localhost|127\.0\.0\.1|\[::1\])(:\d+)?(\/|$)/i.test(server);
    $("vn-remote-row").hidden = !server || local;
  }
  function openSettings() {
    $<HTMLInputElement>("vn-server").value = status?.settings.server ?? "";
    $<HTMLInputElement>("vn-model").value = status?.settings.model ?? "";
    $<HTMLInputElement>("vn-remote").checked = status?.settings.remoteOk ?? false;
    remoteRow();
    dialog.showModal();
  }
  $("vn-server").addEventListener("input", remoteRow);
  $("vn-settings").addEventListener("click", openSettings);
  $("vn-folder").addEventListener("click", () => void attempt(() => invoke("show_voice_notes_folder")));
  dialog.addEventListener("close", async () => {
    if (dialog.returnValue !== "save") return;
    const settings: VoiceSettings = {
      server: $<HTMLInputElement>("vn-server").value.trim(),
      model: $<HTMLInputElement>("vn-model").value.trim(),
      remoteOk: $<HTMLInputElement>("vn-remote").checked,
    };
    const s = await attempt(() => invoke<VoiceStatus>("set_voice_settings", { settings }));
    if (s) status = s;
    void render();
  });

  invoke<VoiceStatus>("voice_settings")
    .then((s) => (status = s))
    .catch(() => undefined);
  void load();
}
