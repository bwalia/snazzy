#!/usr/bin/env python3
"""Writes the website's top menu into every page of site/ (one place to change it):
Product and Resources dropdowns, Use cases, Tours and the Download button, with a
menu button on narrow screens (site/assets/nav.js, styles in site.css).

    python3 Scripts/site-nav.py
"""
import pathlib, re

root = pathlib.Path(__file__).resolve().parent.parent / "site"

PRODUCT = [
    ("#how", "How it works", "Plan, build, rehearse, record and go live"),
    ("#agent", "AI agent", "An assistant that runs the whole studio"),
    ("#features", "Features", "Slides, camera, recording, live and more"),
    ("#live", "Live classroom", "A room on your Wi-Fi, or stream to YouTube"),
    ("#interviews", "Interviews", "Fair first-round interviews for recruiters"),
]
RESOURCES = [
    ("blog/", "Blog", "Guides and what's new"),
    ("prep.html", "Interview Prep", "Free prep packs for candidates"),
    ("#developers", "Developers", "MCP server, Claude Code plugin, open source"),
    ("#faq", "FAQ", "Common questions"),
    ("#privacy", "Privacy", "What stays on your Mac"),
    ("support.html", "Support", "Help and contact"),
]

def header(page: pathlib.Path) -> str:
    rel = page.relative_to(root)
    up = "../" * (len(rel.parts) - 1)
    is_home = rel.as_posix() == "index.html"
    def href(target):
        if target.startswith("#"):
            return target if is_home else f"{up or './'}{target}" if up else f"./{target}"
        return f"{up}{target}"
    def current(target):
        t = rel.as_posix()
        return (target == "blog/" and t.startswith("blog/")) or t == target
    def item(target, title, desc):
        cur = ' aria-current="page"' if current(target) else ""
        return f'<a href="{href(target)}"{cur}><b>{title}</b><span>{desc}</span></a>'
    def menu(name, items):
        return (f'<div class="menu"><button type="button" aria-expanded="false" aria-haspopup="true">{name}</button>'
                f'<div class="panel">{"".join(item(*i) for i in items)}</div></div>')
    tours_cur = ' aria-current="page"' if rel.as_posix() == "tours.html" else ""
    return (f'<header class="nav"><div class="wrap">\n'
            f'  <a class="brand" href="{up or "./"}" aria-label="Snazzy Pro home"><img src="{up}assets/lockup-on-dark.svg" alt="Snazzy Pro" width="130" height="34"></a>\n'
            f'  <nav class="links" aria-label="Site">{menu("Product", PRODUCT)}'
            f'<a href="{href("#use-cases")}">Use cases</a><a href="{up}tours.html"{tours_cur}>Tours</a>'
            f'{menu("Resources", RESOURCES)}</nav>\n'
            f'  <a class="btn small primary" href="{up}download.html">Download</a>\n'
            f'  <button class="burger" type="button" aria-label="Menu" aria-expanded="false"><span></span></button>\n'
            f'</div></header>')

changed = 0
for page in sorted(root.rglob("*.html")):
    text = page.read_text()
    if '<header class="nav"' not in text:
        continue
    up = "../" * (len(page.relative_to(root).parts) - 1)
    new = re.sub(r'<header class="nav".*?</header>', lambda _: header(page), text, count=1, flags=re.S)
    script = f'<script src="{up}assets/nav.js" defer></script>'
    if script not in new:
        new = new.replace("</body>", f"{script}\n</body>", 1)
    if new != text:
        page.write_text(new)
        changed += 1
print(f"{changed} pages updated")
