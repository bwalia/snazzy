# Deck repositories

Any public GitHub repository (or a folder in one) can hold decks people add
with **Get Decks**. User guide: `decks/README.md`.

Source of truth: `Packages/SnazzyKit/Sources/Builder/DeckRepo.swift`.
Fixture: `deck-repo-cases.json` (paste → repo and URLs, tree + catalogue → decks).
Rust: `snazzy_core::deck_repo`.

## What people may paste

`owner/repo`, `owner/repo/folder…`, `github.com/owner/repo`, or a browser link
`https://github.com/owner/repo/tree/<branch>/<folder…>` (`blob` too):

1. Trim; drop a leading `https://`, `http://`, `www.`, then `github.com/`
   (case-insensitive), a trailing `.git`, and everything from `?` or `#`.
2. Split on `/` (empty parts ignored); need at least owner and repo.
3. Owner: ASCII letters, digits, `-`, at most 39 characters. Repo and every
   path part: ASCII letters, digits, `-_.`, 1–100 characters, not `.` or `..`.
4. `…/tree/<branch>/<rest>` (or `blob`): branch (`HEAD` = default branch) and folder.
   Else everything after the repo is the folder.

The official collection is `bwalia/snazzy/decks`.

URLs: API `https://api.github.com/repos/<owner>/<repo>` and
`…/git/trees/<branch>?recursive=1`; files
`https://raw.githubusercontent.com/<owner>/<repo>/<branch>/<path>`; branch and
path parts percent-encoded as `.urlPathAllowed` (letters, digits, `-._~!$&'()*+,;=:@` stay).

## Finding decks

From the recursive tree listing, under the repo folder:

1. Every folder (at most 3 levels down, no part starting with `.`) holding an
   `index.html` is a candidate. A folder inside another candidate is not a deck.
   When there's more than one deck, a top-level `index.html` is the repo's page,
   not a deck.
2. A deck's files: everything under its folder that is a safe path (share.md),
   has no part starting with `.`, has one of the extensions
   `avif css gif htm html jpeg jpg js json m4a md mp3 mp4 otf png svg ttf txt vtt webm webp woff woff2`
   (case-insensitive) and is at most 2,000,000 bytes. Others are left out.
3. Skipped: no `index.html` among those files, more than 80 files, or more than
   40,000,000 bytes in all.
4. `snazzy-decks.json` in the repo folder (optional):
   `{"title":…,"decks":[{"path","title","description","category","tags","author"}]}`,
   every key but `path` optional, paths compared without `/` and spaces at the
   ends, first entry for a path wins.
5. Title: catalogue, else the folder name prettified (`q3_results` →
   `Q3 results`), else the repo name. Category: catalogue, else the parent folder
   prettified (`education/photosynthesis` → `Education`). Tags cleaned like
   project tags.
6. Order: catalogue order first, then by title (the Mac uses a localized
   case-insensitive comparison; Rust compares lower-cased titles).

Each deck carries `origin` = `github:<owner>/<repo>/<folder>`. An imported deck is
a `shared` project (no internet until allowed) named after its folder's last part.
