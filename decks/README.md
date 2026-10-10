# Snazzy Pro decks

Slide decks anyone can add to Snazzy Pro: open **Slides › Get Decks** (or **File › Get Decks from GitHub…**), pick a deck and click **Add to My Decks**.

## Make your own deck repo

Any public GitHub repo works. Paste `owner/repo` (or a github.com link, or `owner/repo/folder`) into **Get Decks › Add Repo**.

1. **One folder per deck, with an `index.html`.** The easiest way to get one: in Snazzy Pro, open the deck in the Builder and use **Show in Finder**, then copy the folder into your repo. Keep `deck.css`, `deck.js` and `deck.json` (`deck.json` lets people edit the slides without AI).
2. **Group decks by folder if you like.** `education/photosynthesis/` puts the deck in the *Education* category.
3. **Optional: add `snazzy-decks.json`** next to the deck folders to set titles, descriptions, categories, tags and authors, and the order they're listed in:

   ```json
   {
     "title": "Our team decks",
     "decks": [
       { "path": "q4-kickoff", "title": "Q4 kick-off", "description": "Goals and owners for Q4.",
         "category": "Company", "tags": ["Planning", "Q4"], "author": "Ops team" }
     ]
   }
   ```

What Snazzy Pro downloads: web files only (HTML, CSS, JavaScript, JSON, images, fonts, short audio and video), at most 80 files and 40 MB per deck, nothing in hidden folders. A deck from GitHub opens **without internet access** until you click **Allow Internet**, like a shared `.snazzy` file.

## Add a deck here

Open a pull request that adds your deck folder and an entry in [`snazzy-decks.json`](snazzy-decks.json). Decks must be yours to share, with made-up or public names and figures only, and no keys, tokens or personal data.
