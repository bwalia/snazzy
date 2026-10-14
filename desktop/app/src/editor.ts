// The slide editor: make and change decks without AI (deck.json, as on the Mac).
import { api, type DeckOutline, type Layout, type OpenDeck, type OutlineSlide } from "./api";
import { attempt, confirmDialog, esc, html } from "./ui";

// snazzy_core::deck::Layout: display_name and items_hint.
const LAYOUTS: { id: Layout; name: string; hint: string }[] = [
  { id: "title", name: "Title", hint: "Subtitle (one line)" },
  { id: "bullets", name: "Bullet points", hint: "One bullet per line" },
  { id: "stats", name: "Big numbers", hint: "Pairs of lines: number, then what it means" },
  { id: "columns", name: "Two columns", hint: "Left label, its points, then right label and its points (split in half)" },
  { id: "quote", name: "Quote", hint: "Who said it (one line)" },
  { id: "steps", name: "Numbered steps", hint: "One step per line" },
  { id: "closing", name: "Closing", hint: "Subtitle (one line)" },
];
// DeckOutline::ACCENTS
const ACCENTS = ["#6C5CFF", "#D946EF", "#FF6A55", "#FFB020", "#34D399", "#38BDF8", "#0F766E", "#3B82F6"];

/** Opens the editor on a deck; resolves with the saved deck, or null if closed without saving. */
export async function editSlides(deck: OpenDeck, startAt = 0): Promise<OpenDeck | null> {
  const loaded = await attempt(() => api.outline(deck.name));
  if (!loaded) return null;
  const outline: DeckOutline = structuredClone(loaded);
  let current = Math.min(Math.max(0, startAt), outline.slides.length - 1);
  let dirty = false;

  const dialog = html<HTMLDialogElement>(`
    <dialog class="editor">
      <form method="dialog" class="dialog">
        <header class="editor-head">
          <input class="title-input" name="title" aria-label="Deck title" />
          <div class="accents" role="radiogroup" aria-label="Accent colour">
            ${ACCENTS.map((c) => `<button type="button" role="radio" class="swatch" style="--c:${c}" data-accent="${c}" aria-label="${c}"></button>`).join("")}
          </div>
        </header>
        <div class="editor-body">
          <aside>
            <ol class="slide-list" aria-label="Slides"></ol>
            <div class="row wrap">
              <button type="button" class="ghost" data-act="add">Add</button>
              <button type="button" class="ghost" data-act="dup">Duplicate</button>
              <button type="button" class="ghost" data-act="up" title="Move up">↑</button>
              <button type="button" class="ghost" data-act="down" title="Move down">↓</button>
              <button type="button" class="ghost danger-text" data-act="del">Delete</button>
            </div>
          </aside>
          <section class="slide-form">
            <label>Layout
              <select name="layout">${LAYOUTS.map((l) => `<option value="${l.id}">${esc(l.name)}</option>`).join("")}</select>
            </label>
            <label>Heading <input name="heading" autocomplete="off" /></label>
            <label><span>Lines <span class="muted small" data-hint></span></span>
              <textarea name="items" rows="6"></textarea>
            </label>
            <label>Speaker notes <textarea name="notes" rows="5" placeholder="What to say on this slide"></textarea></label>
          </section>
        </div>
        <div class="actions">
          <span class="muted small spacer">Saving writes deck.json and index.html.</span>
          <button value="cancel" class="ghost">Close</button>
          <button value="save">Save</button>
        </div>
      </form>
    </dialog>`);
  document.body.appendChild(dialog);
  const form = dialog.querySelector("form")!;
  const field = <T extends HTMLElement>(name: string) => form.elements.namedItem(name) as unknown as T;
  const list = dialog.querySelector<HTMLOListElement>(".slide-list")!;
  const title = field<HTMLInputElement>("title");
  const layout = field<HTMLSelectElement>("layout");
  const heading = field<HTMLInputElement>("heading");
  const items = field<HTMLTextAreaElement>("items");
  const notes = field<HTMLTextAreaElement>("notes");

  function drawList() {
    list.innerHTML = outline.slides
      .map(
        (s, i) =>
          `<li><button type="button" data-i="${i}" aria-current="${i === current}">
            <span class="num">${i + 1}</span>${esc(s.heading || "(no heading)")}
            <span class="muted small">${esc(LAYOUTS.find((l) => l.id === s.layout)?.name ?? s.layout)}</span>
          </button></li>`,
      )
      .join("");
  }
  function drawSlide() {
    const s = outline.slides[current];
    layout.value = s.layout;
    heading.value = s.heading;
    items.value = s.items.join("\n");
    notes.value = s.notes;
    dialog.querySelector("[data-hint]")!.textContent = `(${LAYOUTS.find((l) => l.id === s.layout)?.hint ?? ""})`;
  }
  function drawAccent() {
    dialog.querySelectorAll<HTMLButtonElement>(".swatch").forEach((b) =>
      b.setAttribute("aria-checked", String(b.dataset.accent?.toLowerCase() === outline.accent.toLowerCase())),
    );
  }
  function read() {
    const s = outline.slides[current];
    s.layout = layout.value as Layout;
    s.heading = heading.value;
    s.items = items.value.split("\n").map((l) => l.trim()).filter((l) => l.length > 0);
    s.notes = notes.value.trim();
    outline.title = title.value.trim() || outline.title;
  }

  title.value = outline.title;
  drawList();
  drawSlide();
  drawAccent();

  form.addEventListener("input", () => {
    dirty = true;
    read();
    drawList();
  });
  layout.addEventListener("change", drawSlide);
  list.addEventListener("click", (e) => {
    const b = (e.target as HTMLElement).closest<HTMLButtonElement>("button[data-i]");
    if (!b) return;
    current = Number(b.dataset.i);
    drawList();
    drawSlide();
  });
  dialog.querySelector(".accents")!.addEventListener("click", (e) => {
    const b = (e.target as HTMLElement).closest<HTMLButtonElement>("[data-accent]");
    if (!b) return;
    outline.accent = b.dataset.accent!;
    dirty = true;
    drawAccent();
  });
  dialog.querySelector("aside .row")!.addEventListener("click", async (e) => {
    const act = (e.target as HTMLElement).closest<HTMLButtonElement>("[data-act]")?.dataset.act;
    if (!act) return;
    const s = outline.slides;
    const blank: OutlineSlide = { layout: "bullets", heading: "New slide", items: [], notes: "" };
    if (act === "add") s.splice(++current, 0, blank);
    if (act === "dup") s.splice(current + 1, 0, structuredClone(s[current])), current++;
    if (act === "up" && current > 0) [s[current - 1], s[current]] = [s[current], s[current - 1]], current--;
    if (act === "down" && current < s.length - 1) [s[current + 1], s[current]] = [s[current], s[current + 1]], current++;
    if (act === "del") {
      if (s.length === 1) return;
      if (!(await confirmDialog("Delete this slide?", s[current].heading || "This slide", "Delete", true))) return;
      s.splice(current, 1);
      current = Math.min(current, s.length - 1);
    }
    dirty = true;
    drawList();
    drawSlide();
  });

  return new Promise((resolve) => {
    let saved: OpenDeck | null = null;
    dialog.addEventListener("cancel", async (e) => {
      // Esc: ask first when there are changes.
      e.preventDefault();
      if (!dirty || (await confirmDialog("Close without saving?", "Your changes to the slides will be lost.", "Close", true))) {
        dialog.close();
      }
    });
    form.addEventListener("submit", async (e) => {
      const action = (e.submitter as HTMLButtonElement | null)?.value;
      if (action === "save") {
        e.preventDefault();
        read();
        const result = await attempt(() => api.saveOutline(deck.name, outline));
        if (result) {
          saved = result;
          dialog.close();
        }
      } else if (dirty) {
        e.preventDefault();
        if (await confirmDialog("Close without saving?", "Your changes to the slides will be lost.", "Close", true)) {
          dialog.close();
        }
      }
    });
    dialog.addEventListener("close", () => {
      dialog.remove();
      resolve(saved);
    });
    dialog.showModal();
  });
}
