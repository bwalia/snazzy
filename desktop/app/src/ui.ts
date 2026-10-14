// Small helpers for building the window without a framework.

/** Text safe to put in HTML. */
export function esc(s: string | number | null | undefined): string {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

/** An element from HTML (the first one). */
export function html<T extends HTMLElement = HTMLElement>(markup: string): T {
  const t = document.createElement("template");
  t.innerHTML = markup.trim();
  return t.content.firstElementChild as T;
}

/** Asks a question in a dialog; true when the main button is chosen. */
export function confirmDialog(title: string, message: string, ok: string, danger = false): Promise<boolean> {
  const dialog = html<HTMLDialogElement>(`
    <dialog>
      <form method="dialog" class="dialog">
        <h3>${esc(title)}</h3>
        <p>${esc(message)}</p>
        <div class="actions">
          <button value="no" class="ghost">Cancel</button>
          <button value="yes" class="${danger ? "danger" : ""}">${esc(ok)}</button>
        </div>
      </form>
    </dialog>`);
  document.body.appendChild(dialog);
  dialog.showModal();
  return new Promise((resolve) =>
    dialog.addEventListener(
      "close",
      () => {
        resolve(dialog.returnValue === "yes");
        dialog.remove();
      },
      { once: true },
    ),
  );
}

/** Asks for a line of text; null when cancelled. */
export function promptDialog(title: string, label: string, value = "", ok = "OK"): Promise<string | null> {
  const dialog = html<HTMLDialogElement>(`
    <dialog>
      <form method="dialog" class="dialog">
        <h3>${esc(title)}</h3>
        <label>${esc(label)}<input name="value" value="${esc(value)}" autocomplete="off" /></label>
        <div class="actions">
          <button value="no" class="ghost" formnovalidate>Cancel</button>
          <button value="yes">${esc(ok)}</button>
        </div>
      </form>
    </dialog>`);
  document.body.appendChild(dialog);
  const input = dialog.querySelector("input")!;
  dialog.showModal();
  input.select();
  return new Promise((resolve) =>
    dialog.addEventListener(
      "close",
      () => {
        resolve(dialog.returnValue === "yes" ? input.value : null);
        dialog.remove();
      },
      { once: true },
    ),
  );
}

let toastTimer = 0;

/** A short message at the bottom of the window. */
export function toast(message: string, kind: "info" | "error" = "info") {
  let box = document.getElementById("toast");
  if (!box) {
    box = html(`<div id="toast" role="status" aria-live="polite"></div>`);
    document.body.appendChild(box);
  }
  box.textContent = message;
  box.className = `show ${kind}`;
  window.clearTimeout(toastTimer);
  toastTimer = window.setTimeout(() => box!.classList.remove("show"), kind === "error" ? 7000 : 4000);
}

/** Runs an action and shows its error, if any. */
export async function attempt<T>(action: () => Promise<T>): Promise<T | undefined> {
  try {
    return await action();
  } catch (err) {
    toast(String(err), "error");
    return undefined;
  }
}

export function plural(n: number, word: string): string {
  return `${n} ${word}${n === 1 ? "" : "s"}`;
}
