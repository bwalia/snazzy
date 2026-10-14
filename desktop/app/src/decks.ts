// The Builder (the open deck, live) and the Slides tab: Present · My Decks ·
// Samples · Get Decks. As on the Mac, a button and (from phase 4) the assistant
// call the same commands.
import { listen } from "@tauri-apps/api/event";
import {
  api,
  deckFrame,
  showSlide,
  type DeckSlide,
  type Display,
  type Library,
  type OpenDeck,
  type Presenting,
  type RepoDeck,
  type RepoInfo,
  type SlideHit,
} from "./api";
import { editSlides } from "./editor";
import { attempt, confirmDialog, esc, html, plural, toast } from "./ui";

type Listener = () => void;

/** What every deck view shares: the open deck, its slides and the Present window. */
const deck = {
  open: null as OpenDeck | null,
  slides: [] as DeckSlide[],
  index: 0,
  /** Where to go once the page reports its slides (a search result). */
  pendingSlide: null as number | null,
  presenting: null as Presenting | null,
  errors: [] as string[],
  library: null as Library | null,
  listeners: new Set<Listener>(),
  changed() {
    this.listeners.forEach((l) => l());
  },
};

let frame: HTMLIFrameElement;
let reloads = 0;
let showPanel: (tab: "builder" | "slides", sub?: SlidesView) => void = () => undefined;

type SlidesView = "present" | "decks" | "samples" | "get";

// MARK: Opening

function load(d: OpenDeck, slide: number | null = null) {
  const same = deck.open?.name === d.name;
  deck.open = d;
  deck.errors = [];
  if (!same) {
    deck.slides = [];
    deck.index = 0;
  }
  deck.pendingSlide = slide;
  const start = slide ?? (same ? deck.index : 0);
  frame.src = `${d.url}?v=${++reloads}#${start}`;
  deck.changed();
}

/** Opens a project in the Builder, optionally at a slide. */
export async function openDeck(name: string, slide: number | null = null) {
  if (deck.open?.name === name && slide !== null && deck.slides.length) {
    go(slide);
    showPanel("builder");
    return;
  }
  const d = await attempt(() => api.open(name));
  if (d) {
    load(d, slide);
    showPanel("builder");
  }
}

async function openSample(id: string, slide: number | null = null) {
  const d = await attempt(() => api.openSample(id));
  if (d) {
    load(d, slide);
    showPanel("builder");
    void refreshLibrary();
  }
}

function go(index: number) {
  const max = deck.slides.length - 1;
  const i = Math.max(0, max >= 0 ? Math.min(index, max) : index);
  showSlide(frame, i);
}

async function refreshLibrary() {
  deck.library = (await attempt(() => api.library())) ?? deck.library;
  deck.changed();
}

/** Messages from the deck's bridge script (snazzy_core::preview::BRIDGE_JS). */
function onDeckMessage(e: MessageEvent) {
  if (e.source !== frame.contentWindow || !e.data || typeof e.data !== "object") return;
  const m = e.data as { snazzy?: string; index?: number; slides?: DeckSlide[]; message?: string; url?: string };
  if (m.snazzy === "deck" && typeof m.index === "number") {
    if (m.slides) deck.slides = m.slides;
    if (m.index >= 0) deck.index = m.index;
    if (m.slides && deck.pendingSlide !== null) {
      const target = deck.pendingSlide;
      deck.pendingSlide = null;
      if (target !== deck.index) go(target);
    }
    const p = deck.presenting;
    if (p && p.name === deck.open?.name && p.index !== deck.index) void api.presentGo(deck.index);
    deck.changed();
  } else if (m.snazzy === "console" && m.message) {
    deck.errors = [...deck.errors, m.message].slice(-20);
    deck.changed();
  } else if (m.snazzy === "open" && m.url) {
    void attempt(() => api.openLink(m.url!));
  }
}

function onPresent(p: Presenting | null) {
  deck.presenting = p;
  if (p && p.name === deck.open?.name && p.index !== deck.index) go(p.index);
  deck.changed();
}

// MARK: Actions

async function importFile(file: File) {
  const bytes = new Uint8Array(await file.arrayBuffer());
  const result = await attempt(() => api.importShare(bytes));
  if (!result) return;
  load(result.deck);
  showPanel("builder");
  void refreshLibrary();
  const extra = result.skipped.length
    ? ` It also had ${result.skipped.join(" and ")}, which arrive with Sources & Preview.`
    : "";
  toast(`Added “${result.deck.title}”${result.note ? `: “${result.note}”` : ""}.${extra}`);
}

function chooseFile() {
  const input = html<HTMLInputElement>(`<input type="file" accept=".snazzy" hidden />`);
  input.addEventListener("change", () => {
    const file = input.files?.[0];
    if (file) void importFile(file);
    input.remove();
  });
  document.body.appendChild(input);
  input.click();
}

async function newDeck() {
  const d = await attempt(() => api.newDeck("Untitled deck"));
  if (!d) return;
  load(d);
  showPanel("builder");
  void refreshLibrary();
  const saved = await editSlides(d);
  if (saved) {
    load(saved, 0);
    void refreshLibrary();
  }
}

async function edit() {
  if (!deck.open) return;
  const saved = await editSlides(deck.open, deck.index);
  if (saved) {
    load(saved, deck.index);
    void refreshLibrary();
  }
}

async function details() {
  const d = deck.open;
  if (!d) return;
  const known = new Set([...(deck.library?.decks.map((x) => x.category) ?? []), ...(deck.library?.sectors ?? [])]);
  known.delete("Uncategorised");
  const dialog = html<HTMLDialogElement>(`
    <dialog>
      <form method="dialog" class="dialog">
        <h3>Details</h3>
        <p class="muted small">How “${esc(d.title)}” is filed in My Decks.</p>
        <label>Category <input name="category" list="categories" value="${esc(d.category ?? "")}" maxlength="60" placeholder="e.g. Finance" /></label>
        <datalist id="categories">${[...known].sort().map((c) => `<option value="${esc(c)}"></option>`).join("")}</datalist>
        <label>Tags <input name="tags" value="${esc(d.tags.join(", "))}" placeholder="Comma-separated, e.g. Board, Q3" /></label>
        <div class="actions">
          <button value="no" class="ghost">Cancel</button>
          <button value="yes">Save</button>
        </div>
      </form>
    </dialog>`);
  document.body.appendChild(dialog);
  dialog.showModal();
  dialog.addEventListener("close", async () => {
    const form = dialog.querySelector("form")!;
    const category = (form.elements.namedItem("category") as HTMLInputElement).value;
    const tags = (form.elements.namedItem("tags") as HTMLInputElement).value.split(",");
    const save = dialog.returnValue === "yes";
    dialog.remove();
    if (!save) return;
    const updated = await attempt(() => api.setDetails(d.name, category, tags));
    if (updated) {
      deck.open = updated;
      void refreshLibrary();
    }
  });
}

async function share() {
  const d = deck.open;
  if (!d) return;
  const path = await attempt(() => api.exportDeck(d.name));
  if (path) toast(`Saved ${path}. Send it to anyone with Snazzy Pro; it opens with a double-click.`);
}

async function allowInternet() {
  const d = deck.open;
  if (!d) return;
  const ok = await confirmDialog(
    "Let this deck use the internet?",
    "It came from someone else. With internet access it can load fonts, libraries and data from the web, and send things there.",
    "Allow Internet",
  );
  if (!ok) return;
  const updated = await attempt(() => api.allowInternet(d.name));
  if (updated) load(updated, deck.index);
}

async function remove(name: string, title: string) {
  if (!(await confirmDialog(`Delete “${title}”?`, "The deck's folder and all its files are deleted. This can't be undone.", "Delete", true))) {
    return;
  }
  try {
    await api.remove(name);
  } catch (err) {
    toast(String(err), "error");
    return;
  }
  if (deck.open?.name === name) {
    deck.open = null;
    deck.slides = [];
    frame.removeAttribute("src");
  }
  void refreshLibrary();
}

async function present(display: number | null) {
  const d = deck.open;
  if (!d) return;
  const p = await attempt(() => api.presentOpen(d.name, deck.index, display));
  if (p) onPresent(p);
}

// MARK: Builder

function mountBuilder(root: HTMLElement) {
  root.classList.add("builder");
  root.innerHTML = `
    <div class="empty-state" data-empty>
      <h2>No deck open</h2>
      <p class="muted">Ask the assistant to make a presentation, start from a sample, or make one yourself in the slide editor.</p>
      <div class="row wrap center">
        <button data-act="new">New Deck</button>
        <button class="ghost" data-act="samples">Browse Samples</button>
        <button class="ghost" data-act="import">Open a .snazzy File</button>
      </div>
    </div>
    <div class="deck" data-deck hidden>
      <header class="deck-head">
        <div class="deck-title"><strong data-title></strong><span class="muted small" data-where></span></div>
        <span class="spacer"></span>
        <button class="ghost" data-act="edit" title="Change the slides without AI">Edit Slides</button>
        <button class="ghost" data-act="details" title="Category and tags">Details</button>
        <button class="ghost" data-act="share" title="Save as a .snazzy file in Downloads">Share</button>
        <button data-act="present" title="Present on this or another display">Present</button>
        <button class="ghost danger-text" data-act="delete" title="Delete this deck">Delete</button>
      </header>
      <div class="banner" data-shared hidden>
        <span>From someone else: no internet access, so web fonts, libraries and data won't load.</span>
        <button class="ghost" data-act="internet">Allow Internet</button>
      </div>
      <div class="stage" data-stage></div>
      <footer class="deck-foot">
        <button class="ghost" data-act="prev" title="Previous slide">‹</button>
        <span data-count class="muted small"></span>
        <button class="ghost" data-act="next" title="Next slide">›</button>
        <span class="spacer"></span>
        <span data-errors class="error-text small"></span>
      </footer>
    </div>`;
  frame = deckFrame("deck-frame");
  root.querySelector("[data-stage]")!.appendChild(frame);
  const q = <T extends HTMLElement>(s: string) => root.querySelector<T>(s)!;

  root.addEventListener("click", (e) => {
    const act = (e.target as HTMLElement).closest<HTMLElement>("[data-act]")?.dataset.act;
    if (act === "new") void newDeck();
    if (act === "samples") showPanel("slides", "samples");
    if (act === "import") chooseFile();
    if (act === "edit") void edit();
    if (act === "details") void details();
    if (act === "share") void share();
    if (act === "present") showPanel("slides", "present");
    if (act === "delete" && deck.open) void remove(deck.open.name, deck.open.title);
    if (act === "internet") void allowInternet();
    if (act === "prev") go(deck.index - 1);
    if (act === "next") go(deck.index + 1);
  });

  deck.listeners.add(() => {
    const d = deck.open;
    q("[data-empty]").hidden = !!d;
    q("[data-deck]").hidden = !d;
    if (!d) return;
    q("[data-title]").textContent = d.title;
    q("[data-where]").textContent = [d.category, d.tags.join(", ")].filter(Boolean).join(" · ");
    q("[data-shared]").hidden = !d.shared;
    q<HTMLButtonElement>("[data-act=edit]").hidden = !d.hasOutline;
    q("[data-count]").textContent = deck.slides.length ? `Slide ${deck.index + 1} of ${deck.slides.length}` : "";
    const errors = deck.errors;
    q("[data-errors]").textContent = errors.length ? `${plural(errors.length, "error")}: ${errors[errors.length - 1]}` : "";
  });
}

// MARK: Slides › Present

function mountPresent(root: HTMLElement) {
  root.innerHTML = `
    <div class="empty-state" data-empty>
      <h2>No deck open</h2>
      <p class="muted">Open a deck from My Decks or Samples, then present it from here.</p>
    </div>
    <div class="present" data-body hidden>
      <header class="deck-head">
        <div class="deck-title"><strong data-title></strong><span class="muted small" data-count></span></div>
        <span class="spacer"></span>
        <select data-display aria-label="Display"></select>
        <button data-act="open">Open Present Window</button>
        <button class="ghost" data-act="close" hidden>Close Present Window</button>
      </header>
      <div class="present-body">
        <ol class="slide-list" data-list aria-label="Slides"></ol>
        <section class="notes">
          <div class="row">
            <span class="eyebrow">Speaker notes</span><span class="spacer"></span>
            <button class="ghost" data-act="smaller" title="Smaller notes">A−</button>
            <button class="ghost" data-act="larger" title="Larger notes">A+</button>
          </div>
          <div class="notes-text" data-notes></div>
          <div class="muted small" data-next></div>
        </section>
      </div>
      <footer class="deck-foot">
        <button data-act="prev">‹ Previous</button>
        <button data-act="next">Next ›</button>
        <span class="spacer"></span>
        <span class="timer" data-timer>0:00</span>
        <button class="ghost" data-act="timer">Start</button>
        <button class="ghost" data-act="reset">Reset</button>
      </footer>
    </div>`;
  const q = <T extends HTMLElement>(s: string) => root.querySelector<T>(s)!;
  let size = 22;
  try {
    size = Number(localStorage.getItem("snazzy.notesSize")) || 22;
  } catch {
    /* no storage: the default size */
  }
  let started = 0;
  let elapsed = 0;
  let ticker = 0;

  const displays = q<HTMLSelectElement>("[data-display]");
  async function listDisplays() {
    const list: Display[] = (await attempt(() => api.displays())) ?? [];
    displays.innerHTML =
      `<option value="">In a window</option>` +
      list.map((d) => `<option value="${d.index}">Full screen on ${esc(d.name)}${d.primary ? " (main)" : ""} · ${d.width}×${d.height}</option>`).join("");
    const other = list.find((d) => !d.primary);
    if (other) displays.value = String(other.index);
  }
  void listDisplays();

  function time() {
    const s = Math.floor((elapsed + (started ? Date.now() - started : 0)) / 1000);
    q("[data-timer]").textContent = `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
  }

  root.addEventListener("click", (e) => {
    const t = e.target as HTMLElement;
    const i = t.closest<HTMLElement>("[data-i]")?.dataset.i;
    if (i !== undefined) go(Number(i));
    const act = t.closest<HTMLElement>("[data-act]")?.dataset.act;
    if (act === "open") void present(displays.value === "" ? null : Number(displays.value));
    if (act === "close") void api.presentClose();
    if (act === "prev") go(deck.index - 1);
    if (act === "next") go(deck.index + 1);
    if (act === "smaller" || act === "larger") {
      size = Math.min(48, Math.max(14, size + (act === "larger" ? 2 : -2)));
      try {
        localStorage.setItem("snazzy.notesSize", String(size));
      } catch {
        /* not remembered */
      }
      deck.changed();
    }
    if (act === "timer") {
      if (started) {
        elapsed += Date.now() - started;
        started = 0;
        window.clearInterval(ticker);
      } else {
        started = Date.now();
        ticker = window.setInterval(time, 500);
      }
      q("[data-act=timer]").textContent = started ? "Pause" : "Start";
      time();
    }
    if (act === "reset") {
      elapsed = 0;
      started = started ? Date.now() : 0;
      time();
    }
  });
  root.addEventListener("focusin", () => void listDisplays(), { once: true });

  deck.listeners.add(() => {
    const d = deck.open;
    q("[data-empty]").hidden = !!d;
    q("[data-body]").hidden = !d;
    if (!d) return;
    q("[data-title]").textContent = d.title;
    q("[data-count]").textContent = deck.slides.length ? `Slide ${deck.index + 1} of ${deck.slides.length}` : "Loading…";
    const presentingThis = deck.presenting?.name === d.name;
    q("[data-act=open]").textContent = presentingThis ? "Move Present Window" : "Open Present Window";
    q("[data-act=close]").hidden = !deck.presenting;
    q("[data-list]").innerHTML = deck.slides
      .map(
        (s, i) => `<li><button data-i="${i}" aria-current="${i === deck.index}">
          <span class="num">${i + 1}</span>${esc(s.title || "(untitled)")}${s.notes ? `<span class="muted small" title="Has speaker notes">¶</span>` : ""}
        </button></li>`,
      )
      .join("");
    q("[data-list] [aria-current=true]")?.scrollIntoView({ block: "nearest" });
    const slide = deck.slides[deck.index];
    const notes = q("[data-notes]");
    notes.style.fontSize = `${size}px`;
    notes.textContent = slide?.notes || "";
    notes.classList.toggle("muted", !slide?.notes);
    if (!slide?.notes) notes.textContent = "No notes for this slide. Ask the assistant: “Write speaker notes for every slide.”";
    const next = deck.slides[deck.index + 1];
    q("[data-next]").textContent = next ? `Next: ${next.title || `slide ${deck.index + 2}`}` : "Last slide";
  });
}

// MARK: Slides › My Decks

function mountLibrary(root: HTMLElement) {
  root.innerHTML = `
    <div class="toolbar">
      <input type="search" data-search placeholder="Search every slide, note and tag (Ctrl+Shift+F)" aria-label="Search slides" />
      <button data-act="new">New Deck</button>
      <button class="ghost" data-act="import">Open .snazzy</button>
    </div>
    <div class="chips" data-tags></div>
    <div class="list" data-list></div>`;
  const q = <T extends HTMLElement>(s: string) => root.querySelector<T>(s)!;
  const search = q<HTMLInputElement>("[data-search]");
  let tag: string | null = null;
  let hits: SlideHit[] | null = null;
  let searchTimer = 0;

  search.addEventListener("input", () => {
    window.clearTimeout(searchTimer);
    searchTimer = window.setTimeout(async () => {
      const text = search.value.trim();
      hits = text ? ((await attempt(() => api.search(text))) ?? []) : null;
      draw();
    }, 150);
  });
  root.addEventListener("click", (e) => {
    const t = e.target as HTMLElement;
    const act = t.closest<HTMLElement>("[data-act]")?.dataset.act;
    if (act === "new") void newDeck();
    if (act === "import") chooseFile();
    const chip = t.closest<HTMLElement>("[data-tag]");
    if (chip) {
      tag = tag === chip.dataset.tag ? null : chip.dataset.tag!;
      draw();
    }
    const row = t.closest<HTMLElement>("[data-open]");
    if (row && !t.closest("[data-delete]")) void openDeck(row.dataset.open!);
    const del = t.closest<HTMLElement>("[data-delete]");
    if (del) void remove(del.dataset.delete!, del.dataset.title ?? del.dataset.delete!);
    const hit = t.closest<HTMLElement>("[data-hit]");
    if (hit && hits) {
      const h = hits[Number(hit.dataset.hit)];
      if (h.project) void openDeck(h.project, h.slide);
      else if (h.sample) void openSample(h.sample, h.slide);
    }
  });

  function draw() {
    const lib = deck.library;
    if (!lib) {
      q("[data-list]").innerHTML = `<p class="muted">Loading…</p>`;
      return;
    }
    if (hits) {
      q("[data-tags]").innerHTML = "";
      q("[data-list]").innerHTML = hits.length
        ? hits
            .map(
              (h, i) => `<button class="row-item" data-hit="${i}">
                <span><strong>${esc(h.heading || `Slide ${h.slide + 1}`)}</strong>
                <span class="muted small">${esc(h.deckTitle)} · slide ${h.slide + 1}${h.sample ? " · sample" : ""}${h.field === "notes" ? " · in the notes" : ""}</span></span>
                <span class="snippet">${esc(h.snippet)}</span>
              </button>`,
            )
            .join("")
        : `<p class="muted">No slides match. Search looks at titles, slide text, speaker notes and tags.</p>`;
      return;
    }
    const decks = lib.decks.filter((d) => d.kind === "presentation");
    const tags = [...new Set(decks.flatMap((d) => d.tags))].sort((a, b) => a.localeCompare(b));
    if (tag && !tags.includes(tag)) tag = null;
    q("[data-tags]").innerHTML = tags
      .map((t) => `<button class="chip" data-tag="${esc(t)}" aria-pressed="${t === tag}">#${esc(t)}</button>`)
      .join("");
    const shown = decks.filter((d) => !tag || d.tags.includes(tag));
    if (!decks.length) {
      q("[data-list]").innerHTML = `<div class="empty-state"><h2>No decks yet</h2>
        <p class="muted">Ask the assistant for one, open a sample, or press New Deck.</p></div>`;
      return;
    }
    const groups = new Map<string, typeof shown>();
    for (const d of [...shown].sort((a, b) => a.title.localeCompare(b.title))) {
      groups.set(d.category, [...(groups.get(d.category) ?? []), d]);
    }
    const order = [...groups.keys()].sort((a, b) =>
      a === "Uncategorised" ? 1 : b === "Uncategorised" ? -1 : a.localeCompare(b),
    );
    q("[data-list]").innerHTML = order
      .map(
        (c) => `<h3 class="group">${esc(c)} <span class="muted small">${groups.get(c)!.length}</span></h3>` +
          groups
            .get(c)!
            .map(
              (d) => `<div class="row-item" data-open="${esc(d.name)}" role="button" tabindex="0" aria-current="${d.name === deck.open?.name}">
                <span><strong>${esc(d.title)}</strong>
                <span class="muted small">${plural(d.slides, "slide")}${d.tags.length ? ` · ${d.tags.map((t) => `#${esc(t)}`).join(" ")}` : ""}</span></span>
                ${d.shared ? `<span class="badge warn" title="From someone else: no internet until you allow it">No internet</span>` : ""}
                <button class="ghost small danger-text" data-delete="${esc(d.name)}" data-title="${esc(d.title)}" title="Delete">Delete</button>
              </div>`,
            )
            .join(""),
      )
      .join("");
  }

  root.addEventListener("keydown", (e) => {
    const row = (e.target as HTMLElement).closest<HTMLElement>("[data-open]");
    if (row && (e.key === "Enter" || e.key === " ") && e.target === row) {
      e.preventDefault();
      void openDeck(row.dataset.open!);
    }
  });
  deck.listeners.add(draw);
  return () => search.focus();
}

// MARK: Slides › Samples

function mountSamples(root: HTMLElement) {
  root.innerHTML = `<p class="muted small">Twelve ready decks, one per sector, with speaker notes on every slide. Opening one copies it into My Decks, where you can change it.</p><div data-list></div>`;
  const list = root.querySelector<HTMLElement>("[data-list]")!;
  root.addEventListener("click", (e) => {
    const id = (e.target as HTMLElement).closest<HTMLElement>("[data-sample]")?.dataset.sample;
    if (id) void openSample(id);
  });
  deck.listeners.add(() => {
    const lib = deck.library;
    if (!lib) return;
    list.innerHTML = lib.sectors
      .map((sector) => {
        const samples = lib.samples.filter((s) => s.sector === sector);
        return `<h3 class="group">${esc(sector)}</h3>` +
          samples
            .map(
              (s) => `<article class="card" style="--card-accent:${esc(s.accent)}">
                <div class="card-head"><strong>${esc(s.title)}</strong>
                  <button class="${s.opened ? "ghost" : ""}" data-sample="${esc(s.id)}">${s.opened ? "Open" : "Open Sample"}</button></div>
                <p>${esc(s.useCase)}</p>
                <p class="muted small">${esc(s.audience)} · ${s.minutes} min · ${plural(s.slides, "slide")}</p>
                <details><summary class="small">How to record it</summary>
                  <ul class="small">${s.setup.map((x) => `<li>${esc(x)}</li>`).join("")}</ul>
                  <p class="small muted">To make one like it, ask: “${esc(s.prompt)}”</p>
                </details>
              </article>`,
            )
            .join("");
      })
      .join("");
  });
}

// MARK: Slides › Get Decks

function mountGetDecks(root: HTMLElement) {
  root.innerHTML = `
    <div class="toolbar">
      <select data-repo aria-label="Deck repo"></select>
      <button class="ghost" data-act="refresh" title="Ask GitHub again">Refresh</button>
      <button class="ghost" data-act="github">View on GitHub</button>
      <button class="ghost danger-text" data-act="remove" hidden>Remove</button>
    </div>
    <form class="toolbar" data-add>
      <input name="repo" placeholder="Add a repo: owner/repo or a github.com link" aria-label="Add a deck repo" />
      <button>Add</button>
    </form>
    <p class="muted small">Lists decks in public GitHub repos and downloads the one you add. Nothing about you is sent.
      Added decks have no internet access until you allow it.</p>
    <div class="list" data-list></div>`;
  const q = <T extends HTMLElement>(s: string) => root.querySelector<T>(s)!;
  const select = q<HTMLSelectElement>("[data-repo]");
  let repos: RepoInfo[] = [];
  let decks: RepoDeck[] = [];
  let status = "";
  const progress = new Map<string, string>();
  let started = false;

  async function loadRepos(select_id?: string) {
    repos = (await attempt(() => api.repos())) ?? [];
    select.innerHTML = repos.map((r) => `<option value="${esc(r.id)}">${esc(r.official ? `${r.name} (Snazzy Pro)` : r.name)}</option>`).join("");
    if (select_id) select.value = select_id;
    await loadDecks(false);
  }
  async function loadDecks(force: boolean) {
    const id = select.value;
    q("[data-act=remove]").hidden = repos.find((r) => r.id === id)?.official ?? true;
    decks = [];
    status = "Asking GitHub…";
    draw();
    try {
      decks = await api.repoDecks(id, force);
      status = decks.length ? "" : "No decks here.";
    } catch (err) {
      status = String(err);
    }
    draw();
  }
  function draw() {
    q("[data-list]").innerHTML =
      (status ? `<p class="muted">${esc(status)}</p>` : "") +
      decks
        .map(
          (d) => `<article class="card">
            <div class="card-head"><strong>${esc(d.title)}</strong>
              ${progress.has(d.id)
                ? `<span class="muted small">${esc(progress.get(d.id)!)}</span>`
                : `<button class="${d.added ? "ghost" : ""}" data-add-deck="${esc(d.id)}">${d.added ? "Open" : "Add to My Decks"}</button>`}
            </div>
            ${d.description ? `<p>${esc(d.description)}</p>` : ""}
            <p class="muted small">${[d.category, d.author ? `by ${d.author}` : "", plural(d.files, "file"), `${Math.max(1, Math.round(d.bytes / 1024))} KB`]
              .filter(Boolean)
              .map(esc)
              .join(" · ")}${d.tags.length ? ` · ${d.tags.map((t) => `#${esc(t)}`).join(" ")}` : ""}</p>
          </article>`,
        )
        .join("");
  }

  select.addEventListener("change", () => void loadDecks(false));
  q("[data-add]").addEventListener("submit", async (e) => {
    e.preventDefault();
    const input = (e.target as HTMLFormElement).elements.namedItem("repo") as HTMLInputElement;
    const repo = await attempt(() => api.addRepo(input.value));
    if (repo) {
      input.value = "";
      await loadRepos(repo.id);
    }
  });
  root.addEventListener("click", async (e) => {
    const t = e.target as HTMLElement;
    const act = t.closest<HTMLElement>("[data-act]")?.dataset.act;
    if (act === "refresh") void loadDecks(true);
    if (act === "github") {
      const r = repos.find((x) => x.id === select.value);
      if (r) void attempt(() => api.openLink(r.url));
    }
    if (act === "remove") {
      const r = repos.find((x) => x.id === select.value);
      if (r && (await confirmDialog(`Remove ${r.name}?`, "Decks you've added from it stay in My Decks.", "Remove"))) {
        await api.removeRepo(r.id);
        await loadRepos();
      }
    }
    const id = t.closest<HTMLElement>("[data-add-deck]")?.dataset.addDeck;
    if (id) {
      const d = decks.find((x) => x.id === id);
      if (d?.added) return void openDeck(d.added);
      progress.set(id, "Downloading…");
      draw();
      const opened = await attempt(() => api.addRepoDeck(select.value, id));
      progress.delete(id);
      if (opened) {
        if (d) d.added = opened.name;
        load(opened);
        showPanel("builder");
        void refreshLibrary();
        toast(`Added “${opened.title}”. It has no internet access until you allow it.`);
      }
      draw();
    }
  });
  void listen<{ id: string; done: number; total: number }>("deck-adding", (e) => {
    progress.set(e.payload.id, `Downloading ${e.payload.done} of ${e.payload.total}…`);
    draw();
  });

  // GitHub is only asked when this view is first shown.
  return () => {
    if (!started) {
      started = true;
      void loadRepos();
    }
  };
}

// MARK: Mounting

/** Sets up the Builder and Slides panels inside the main window's panel area. */
export function mountDecks(builder: HTMLElement, slides: HTMLElement, show: (tab: "builder" | "slides") => void) {
  window.addEventListener("message", onDeckMessage);
  mountBuilder(builder);

  slides.innerHTML = `
    <nav class="subtabs" role="tablist">
      <button role="tab" data-view="present">Present</button>
      <button role="tab" data-view="decks">My Decks</button>
      <button role="tab" data-view="samples">Samples</button>
      <button role="tab" data-view="get">Get Decks</button>
    </nav>
    <div class="view" data-pane="present"></div>
    <div class="view" data-pane="decks"></div>
    <div class="view" data-pane="samples"></div>
    <div class="view" data-pane="get"></div>`;
  const pane = (v: SlidesView) => slides.querySelector<HTMLElement>(`[data-pane=${v}]`)!;
  mountPresent(pane("present"));
  const focusSearch = mountLibrary(pane("decks"));
  mountSamples(pane("samples"));
  const startGetDecks = mountGetDecks(pane("get"));

  let view: SlidesView = "decks";
  function showView(v: SlidesView) {
    view = v;
    slides.querySelectorAll<HTMLElement>("[data-view]").forEach((b) => b.setAttribute("aria-selected", String(b.dataset.view === v)));
    slides.querySelectorAll<HTMLElement>("[data-pane]").forEach((p) => (p.hidden = p.dataset.pane !== v));
    if (v === "get") startGetDecks();
    if (v === "decks" || v === "samples") void refreshLibrary();
  }
  slides.querySelector("nav")!.addEventListener("click", (e) => {
    const v = (e.target as HTMLElement).closest<HTMLElement>("[data-view]")?.dataset.view as SlidesView | undefined;
    if (v) showView(v);
  });
  showView(view);

  showPanel = (tab, sub) => {
    show(tab);
    if (tab === "slides" && sub) showView(sub);
  };

  document.addEventListener("keydown", (e) => {
    if ((e.ctrlKey || e.metaKey) && e.shiftKey && e.key.toLowerCase() === "f") {
      e.preventDefault();
      showPanel("slides", "decks");
      focusSearch();
    }
  });

  void listen<Presenting | null>("present", (e) => onPresent(e.payload));
  void api.presentState().then(onPresent, () => undefined);
  void refreshLibrary();

  // Double-clicked .snazzy file: ask before adding it.
  void api.openedFile().then(async (path) => {
    if (!path) return;
    const name = path.split(/[\\/]/).pop() ?? path;
    const ok = await confirmDialog(`Add “${name}”?`, "It's a deck from someone else. It won't have internet access until you allow it.", "Add to My Decks");
    const result = await attempt(() => api.importOpenedFile(ok));
    if (result) {
      load(result.deck);
      showPanel("builder");
      void refreshLibrary();
    }
  }, () => undefined);
}
