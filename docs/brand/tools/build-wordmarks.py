#!/usr/bin/env python3
# Usage: python3 docs/brand/tools/build-wordmarks.py docs/brand
"""Builds the Snazzy Pro wordmark SVGs with text converted to outlines (Manrope ExtraBold)."""
import sys
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.boundsPen import BoundsPen

brand = sys.argv[1]
font = instantiateVariableFont(TTFont(f"{brand}/fonts/Manrope-Variable.ttf"), {"wght": 800})
gs = font.getGlyphSet()
cmap = font.getBestCmap()
upm = font["head"].unitsPerEm

def text_path(text, size, x, baseline, tracking=0.0):
    """SVG path data for text at (x, baseline); returns (d, width)."""
    scale = size / upm
    pen = SVGPathPen(gs)
    cx = 0.0
    for ch in text:
        g = cmap[ord(ch)]
        tp = TransformPen(pen, (scale, 0, 0, -scale, x + cx, baseline))
        gs[g].draw(tp)
        cx += gs[g].width * scale + tracking * size
    return pen.getCommands(), cx - tracking * size

GLYPH = """
    <rect x="190" y="262" width="580" height="410" rx="78" fill="url(#spotlight)"/>
    <path transform="translate(342 432) scale(96)" fill="#FFFFFF" d="M0,-1 C0.1,-0.28 0.28,-0.1 1,0 C0.28,0.1 0.1,0.28 0,1 C-0.1,0.28 -0.28,0.1 -1,0 C-0.28,-0.1 -0.1,-0.28 0,-1 Z"/>
    <path transform="translate(468 336) scale(38)" fill="#FFFFFF" fill-opacity="0.85" d="M0,-1 C0.1,-0.28 0.28,-0.1 1,0 C0.28,0.1 0.1,0.28 0,1 C-0.1,0.28 -0.28,0.1 -1,0 C-0.28,-0.1 -0.1,-0.28 0,-1 Z"/>
    <rect x="548" y="520" width="316" height="226" rx="56" fill="#0E1330" stroke="#FFFFFF" stroke-width="16"/>
    <circle cx="706" cy="633" r="70" fill="#141A40" stroke="#3A4386" stroke-width="7"/><circle cx="706" cy="633" r="46" fill="#FF4D5E"/>"""

DEFS = """<defs><linearGradient id="spotlight" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="#6C5CFF"/><stop offset="0.52" stop-color="#D946EF"/><stop offset="1" stop-color="#FF6A55"/>
  </linearGradient></defs>"""

def lockup(text_color, filename, title):
    # Glyph 740x550 scaled to height 220 at (24, 40).
    gscale = 220 / 550
    gx, gy = 24, 40
    words, ww = text_path("Snazzy", 150, 0, 0, tracking=-0.025)
    tx = gx + 740 * gscale + 44
    baseline = gy + 110 + 54  # optically centred on the glyph
    words, ww = text_path("Snazzy", 150, tx, baseline, tracking=-0.025)
    pro, pw = text_path("Pro", 88, 0, 0, tracking=-0.01)
    pill_h, pad = 112, 40
    pill_w = pw + pad * 2
    px = tx + ww + 26
    py = baseline - 110 + 4
    pro, _ = text_path("Pro", 88, px + pad, py + pill_h / 2 + 31, tracking=-0.01)
    width = int(px + pill_w + 24)
    height = 300
    svg = f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" width="{width}" height="{height}">
  <title>{title}</title>
  {DEFS}
  <g transform="translate({gx} {gy}) scale({gscale:.5f}) translate(-160 -230)">{GLYPH}
  </g>
  <path fill="{text_color}" d="{words}"/>
  <rect x="{px:.1f}" y="{py:.1f}" width="{pill_w:.1f}" height="{pill_h}" rx="{pill_h/2}" fill="url(#spotlight)"/>
  <path fill="#FFFFFF" d="{pro}"/>
</svg>
"""
    open(f"{brand}/{filename}", "w").write(svg)
    return width, height

def wordmark_only(text_color, filename, title):
    words, ww = text_path("Snazzy", 150, 20, 150)
    pro, pw = text_path("Pro", 88, 0, 0, tracking=-0.01)
    words, ww = text_path("Snazzy", 150, 20, 150, tracking=-0.025)
    pill_h, pad = 112, 40
    px = 20 + ww + 26
    py = 150 - 106
    pro, _ = text_path("Pro", 88, px + pad, py + pill_h / 2 + 31, tracking=-0.01)
    width = int(px + pw + pad * 2 + 20)
    svg = f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} 200" width="{width}" height="200">
  <title>{title}</title>
  {DEFS}
  <path fill="{text_color}" d="{words}"/>
  <rect x="{px:.1f}" y="{py:.1f}" width="{pw + pad*2:.1f}" height="{pill_h}" rx="{pill_h/2}" fill="url(#spotlight)"/>
  <path fill="#FFFFFF" d="{pro}"/>
</svg>
"""
    open(f"{brand}/{filename}", "w").write(svg)
    return width, 200

print(lockup("#0B1020", "lockup.svg", "Snazzy Pro logo, horizontal lockup, for light backgrounds"))
print(lockup("#FFFFFF", "lockup-on-dark.svg", "Snazzy Pro logo, horizontal lockup, for dark backgrounds"))
print(wordmark_only("#0B1020", "wordmark.svg", "Snazzy Pro wordmark, for light backgrounds"))
print(wordmark_only("#FFFFFF", "wordmark-on-dark.svg", "Snazzy Pro wordmark, for dark backgrounds"))
