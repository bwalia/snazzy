// The app's deck commands (src-tauri/src/decks.rs) and what they return.
import { invoke } from "@tauri-apps/api/core";

export type ProjectKind = "presentation" | "prototype";
export type Layout = "title" | "bullets" | "stats" | "columns" | "quote" | "steps" | "closing";

export interface OpenDeck {
  name: string;
  title: string;
  kind: ProjectKind;
  url: string;
  shared: boolean;
  hasOutline: boolean;
  files: string[];
  category: string | null;
  tags: string[];
  origin: string | null;
}

export interface LibraryDeck {
  name: string;
  title: string;
  kind: ProjectKind;
  category: string;
  tags: string[];
  slides: number;
  created: number | null;
  shared: boolean;
  origin: string | null;
}

export interface LibrarySample {
  id: string;
  sector: string;
  title: string;
  useCase: string;
  audience: string;
  minutes: number;
  slides: number;
  setup: string[];
  prompt: string;
  accent: string;
  opened: string | null;
}

export interface Library {
  decks: LibraryDeck[];
  samples: LibrarySample[];
  sectors: string[];
}

export interface SlideHit {
  project: string | null;
  sample: string | null;
  deckTitle: string;
  slide: number;
  heading: string;
  field: "heading" | "text" | "notes";
  snippet: string;
}

export interface OutlineSlide {
  layout: Layout;
  heading: string;
  items: string[];
  notes: string;
}

export interface DeckOutline {
  title: string;
  accent: string;
  slides: OutlineSlide[];
}

export interface Imported {
  deck: OpenDeck;
  note: string;
  skipped: string[];
}

export interface Presenting {
  name: string;
  title: string;
  url: string;
  index: number;
}

export interface Display {
  index: number;
  name: string;
  width: number;
  height: number;
  primary: boolean;
}

export interface RepoInfo {
  id: string;
  name: string;
  url: string;
  official: boolean;
}

export interface RepoDeck {
  id: string;
  title: string;
  description: string;
  category: string | null;
  tags: string[];
  author: string | null;
  files: number;
  bytes: number;
  url: string;
  added: string | null;
}

/** What a deck's bridge script reports (snazzy_core::preview::BRIDGE_JS). */
export interface DeckSlide {
  title: string;
  notes: string;
  isTitle: boolean;
}

export const api = {
  library: () => invoke<Library>("deck_library"),
  search: (query: string) => invoke<SlideHit[]>("search_slides", { query }),
  open: (name: string) => invoke<OpenDeck>("open_deck", { name }),
  openSample: (id: string) => invoke<OpenDeck>("open_sample", { id }),
  newDeck: (title: string) => invoke<OpenDeck>("new_deck", { title }),
  outline: (name: string) => invoke<DeckOutline | null>("deck_outline", { name }),
  saveOutline: (name: string, outline: DeckOutline) => invoke<OpenDeck>("save_deck_outline", { name, outline }),
  setDetails: (name: string, category: string | null, tags: string[]) =>
    invoke<OpenDeck>("set_deck_details", { name, category, tags }),
  allowInternet: (name: string) => invoke<OpenDeck>("allow_deck_internet", { name }),
  remove: (name: string) => invoke<void>("delete_deck", { name }),
  importShare: (bytes: Uint8Array) => invoke<Imported>("import_share", bytes),
  openedFile: () => invoke<string | null>("opened_file"),
  importOpenedFile: (accept: boolean) => invoke<Imported | null>("import_opened_file", { accept }),
  exportDeck: (name: string) => invoke<string>("export_deck", { name }),
  showDownloads: () => invoke<void>("show_downloads"),
  openLink: (url: string) => invoke<void>("open_link", { url }),
  displays: () => invoke<Display[]>("displays"),
  presentOpen: (name: string, index: number, display: number | null) =>
    invoke<Presenting>("present_open", { name, index, display }),
  presentState: () => invoke<Presenting | null>("present_state"),
  presentGo: (index: number) => invoke<Presenting | null>("present_go", { index }),
  presentFullscreen: (on?: boolean) => invoke<boolean>("present_fullscreen", { on }),
  presentClose: () => invoke<void>("present_close"),
  repos: () => invoke<RepoInfo[]>("deck_repos"),
  addRepo: (text: string) => invoke<RepoInfo>("add_deck_repo", { text }),
  removeRepo: (id: string) => invoke<void>("remove_deck_repo", { id }),
  repoDecks: (id: string, force = false) => invoke<RepoDeck[]>("list_repo_decks", { id, force }),
  addRepoDeck: (repoId: string, deckId: string) => invoke<OpenDeck>("add_repo_deck", { repoId, deckId }),
};

/** Shows a slide in a deck's frame (the bridge obeys `{snazzy: "show"}`). */
export function showSlide(frame: HTMLIFrameElement | null, index: number) {
  frame?.contentWindow?.postMessage({ snazzy: "show", index }, "*");
}

/** The sandbox for deck frames: scripts and its own files, never the app window. */
export function deckFrame(className: string): HTMLIFrameElement {
  const frame = document.createElement("iframe");
  frame.className = className;
  frame.setAttribute(
    "sandbox",
    "allow-scripts allow-same-origin allow-forms allow-modals allow-popups allow-downloads allow-pointer-lock",
  );
  frame.setAttribute("allow", "fullscreen; autoplay");
  frame.setAttribute("referrerpolicy", "no-referrer");
  return frame;
}
