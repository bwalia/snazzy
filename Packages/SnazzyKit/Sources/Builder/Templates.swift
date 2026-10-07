import Foundation

/// Starter files, so the assistant edits a working page instead of starting blank.
enum Templates {
    static func files(for kind: ProjectKind, title: String) -> [(String, String)] {
        let safeTitle = title.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        switch kind {
        case .prototype:
            return [
                ("index.html", """
                <!doctype html>
                <html lang="en">
                <head>
                  <meta charset="utf-8">
                  <meta name="viewport" content="width=device-width, initial-scale=1">
                  <title>\(safeTitle)</title>
                  <link rel="stylesheet" href="style.css">
                </head>
                <body>
                  <main id="app">
                    <h1>\(safeTitle)</h1>
                    <p>Prototype starting point.</p>
                  </main>
                  <script src="app.js"></script>
                </body>
                </html>

                """),
                ("style.css", """
                :root { color-scheme: light dark; --accent: #4f7cff; }
                * { box-sizing: border-box; }
                body { margin: 0; font: 16px/1.5 -apple-system, system-ui, sans-serif; }
                main { max-width: 960px; margin: 0 auto; padding: 32px 24px; }

                """),
                ("app.js", """
                // App logic goes here.
                document.addEventListener('DOMContentLoaded', () => {});

                """),
            ]
        case .presentation:
            return [
                ("index.html", """
                <!doctype html>
                <html lang="en">
                <head>
                  <meta charset="utf-8">
                  <title>\(safeTitle)</title>
                  <link rel="stylesheet" href="deck.css">
                </head>
                <body>
                  <!-- One <section class="slide"> per slide. Speaker notes go in <aside class="notes">. -->
                  <div class="deck">
                    <section class="slide title">
                      <h1>\(safeTitle)</h1>
                      <p class="subtitle">Subtitle</p>
                      <aside class="notes">Speaker notes for the title slide.</aside>
                    </section>
                    <section class="slide">
                      <h2>Agenda</h2>
                      <ul><li>First point</li><li>Second point</li><li>Third point</li></ul>
                    </section>
                  </div>
                  <div class="counter"></div>
                  <script src="deck.js"></script>
                </body>
                </html>

                """),
                ("deck.css", """
                :root { --bg: #0f1420; --fg: #f2f4f8; --muted: #9aa3b5; --accent: #5b8cff; }
                html, body { margin: 0; height: 100%; background: #000; overflow: hidden;
                  font-family: -apple-system, system-ui, sans-serif; }
                .deck { position: absolute; inset: 0; display: grid; place-items: center; }
                .slide { display: none; width: 1600px; height: 900px; padding: 90px 110px; box-sizing: border-box;
                  background: var(--bg); color: var(--fg); transform-origin: center; position: absolute; }
                .slide.active { display: flex; flex-direction: column; justify-content: center; }
                .slide h1 { font-size: 96px; margin: 0 0 24px; }
                .slide h2 { font-size: 64px; margin: 0 0 40px; color: var(--accent); }
                .slide p, .slide li { font-size: 40px; line-height: 1.4; }
                .slide .subtitle { color: var(--muted); }
                .slide .notes { display: none; }
                .counter { position: fixed; right: 16px; bottom: 12px; color: #888; font-size: 14px; }

                """),
                ("deck.js", """
                // 16:9 slides scaled to the window. Arrow keys / space / click to navigate.
                const slides = [...document.querySelectorAll('.slide')];
                let current = Math.min(Number(location.hash.slice(1)) || 0, slides.length - 1);
                function fit() {
                  const s = Math.min(innerWidth / 1600, innerHeight / 900);
                  slides.forEach(el => el.style.transform = `scale(${s})`);
                }
                function show(i) {
                  current = Math.max(0, Math.min(i, slides.length - 1));
                  slides.forEach((el, n) => el.classList.toggle('active', n === current));
                  document.querySelector('.counter').textContent = `${current + 1} / ${slides.length}`;
                  history.replaceState(null, '', '#' + current);
                }
                addEventListener('resize', fit);
                addEventListener('keydown', e => {
                  if (['ArrowRight', 'PageDown', ' '].includes(e.key)) show(current + 1);
                  if (['ArrowLeft', 'PageUp'].includes(e.key)) show(current - 1);
                });
                addEventListener('click', () => show(current + 1));
                window.snazzyDeck = { show, count: () => slides.length, current: () => current };
                fit(); show(current);

                """),
            ]
        }
    }
}
