#!/usr/bin/env python3
"""make_deck.py - turn a JSON list of slides into a single self-contained HTML deck.

WHY THIS EXISTS
  Hermes' weaker fallback models fumble or fake multi-step "build me a deck"
  tasks: they invent file paths, claim a PPTX exists, or paste half-rendered
  markup into the chat. This script is the deterministic helper for the
  "presentations" capability. The agent supplies ONLY the content (a JSON list
  of slides); this script owns the design, the markup, and writing the file.
  Presentations are HTML here, never PowerPoint/PPTX. Open the HTML in a
  browser and print to PDF if a PDF is needed.

USAGE
  # from a file
  bin/make_deck.py --slides slides.json --out /opt/data/decks/q3.html --title "Q3 Review"
  # from stdin
  cat slides.json | bin/make_deck.py --out deck.html
  echo '[{"type":"cover","title":"Hello"}]' | bin/make_deck.py --out d.html

INPUT
  A JSON list of slide objects, OR an object {"title": ..., "slides": [...]}.
  Each slide has a "type" (cover | content | stat | cards | closing) and the
  fields that type uses. This reader is FORGIVING of field-name variations so a
  model that says "points" / "items" / "bullets" all work, "subtitle"/"sub"
  both work, etc. Unknown fields are ignored; missing fields degrade quietly.

SLIDE TYPES (with accepted field aliases)
  cover    title/heading, subtitle/sub/tagline, footer/note
  content  title/heading, points/items/bullets/lines (list of str or {text,...}),
           body/text/paragraph (a paragraph instead of/above bullets)
  stat     title/heading, then EITHER stats/metrics (list of {value/number,label})
           OR flat stat1/label1 .. stat4/label4, OR a single number/value+label
  cards    title/heading, cards/items (list of {title/heading, text/body/desc,
           or its own points/items list})
  closing  title/heading, subtitle/sub, cta/call_to_action, footer/note

OUTPUT
  Writes the HTML to --out and prints a one-line JSON receipt:
    {"ok": true, "out": "...", "slides": N, "bytes": M}
  On bad input prints {"ok": false, "error": "..."} to stdout and exits 1.
"""
from __future__ import annotations

import argparse
import html
import json
import sys
from pathlib import Path


# ----------------------------------------------------------------------------
# forgiving field access
# ----------------------------------------------------------------------------
def _first(d, *keys, default=None):
    """Return the first present, non-None value among keys (dict-aware)."""
    if not isinstance(d, dict):
        return default
    for k in keys:
        if k in d and d[k] is not None:
            return d[k]
    return default


def _as_list(v):
    """Coerce a value into a list of items. None -> []. Scalar -> [scalar]."""
    if v is None:
        return []
    if isinstance(v, (list, tuple)):
        return list(v)
    return [v]


def _text_of(item):
    """Pull display text out of a str or a {text/label/title/...} dict."""
    if item is None:
        return ""
    if isinstance(item, str):
        return item
    if isinstance(item, (int, float)):
        return str(item)
    if isinstance(item, dict):
        return str(_first(item, "text", "label", "title", "heading", "name", "value", default=""))
    return str(item)


def esc(s) -> str:
    return html.escape("" if s is None else str(s), quote=True)


# ----------------------------------------------------------------------------
# per-type slide renderers -> inner HTML for one <section>
# ----------------------------------------------------------------------------
def _points_html(slide):
    pts = _first(slide, "points", "items", "bullets", "lines", default=None)
    pts = [_text_of(p) for p in _as_list(pts) if _text_of(p).strip()]
    if not pts:
        return ""
    lis = "\n".join(f"      <li>{esc(p)}</li>" for p in pts)
    return f"    <ul class='points'>\n{lis}\n    </ul>"


def render_cover(slide):
    title = esc(_first(slide, "title", "heading", default="Untitled"))
    sub = _first(slide, "subtitle", "sub", "tagline", "subheading", default="")
    footer = _first(slide, "footer", "note", "caption", default="")
    parts = [f"    <h1 class='cover-title'>{title}</h1>"]
    if sub:
        parts.append(f"    <p class='cover-sub'>{esc(sub)}</p>")
    if footer:
        parts.append(f"    <p class='cover-footer'>{esc(footer)}</p>")
    return "<div class='slide-inner cover'>\n" + "\n".join(parts) + "\n  </div>"


def render_content(slide):
    title = esc(_first(slide, "title", "heading", default=""))
    body = _first(slide, "body", "text", "paragraph", "desc", "description", default="")
    parts = []
    if title:
        parts.append(f"    <h2>{title}</h2>")
    if body:
        parts.append(f"    <p class='lead'>{esc(body)}</p>")
    pts = _points_html(slide)
    if pts:
        parts.append(pts)
    if not parts:
        parts.append("    <h2>(empty slide)</h2>")
    return "<div class='slide-inner content'>\n" + "\n".join(parts) + "\n  </div>"


def _normalize_stats(slide):
    """Return a list of (value, label) tuples from many possible shapes."""
    out = []
    stats = _first(slide, "stats", "metrics", "numbers", "kpis", default=None)
    if stats:
        for s in _as_list(stats):
            if isinstance(s, dict):
                val = _first(s, "value", "number", "stat", "figure", "num", default="")
                lab = _first(s, "label", "caption", "name", "title", default="")
            else:
                val, lab = _text_of(s), ""
            out.append((str(val), str(lab)))
        return out
    # flat stat1/label1 .. stat6/label6 (also numberN, valueN)
    for i in range(1, 7):
        val = _first(slide, f"stat{i}", f"number{i}", f"value{i}", default=None)
        if val is None:
            continue
        lab = _first(slide, f"label{i}", f"caption{i}", default="")
        out.append((str(val), str(lab)))
    if out:
        return out
    # single number + label fallback
    val = _first(slide, "number", "value", "stat", "figure", default=None)
    if val is not None:
        out.append((str(val), str(_first(slide, "label", "caption", default=""))))
    return out


def render_stat(slide):
    title = esc(_first(slide, "title", "heading", default=""))
    stats = _normalize_stats(slide)
    parts = []
    if title:
        parts.append(f"    <h2>{title}</h2>")
    if stats:
        cells = []
        for val, lab in stats:
            cell = f"      <div class='stat'><div class='stat-value'>{esc(val)}</div>"
            if lab:
                cell += f"<div class='stat-label'>{esc(lab)}</div>"
            cell += "</div>"
            cells.append(cell)
        parts.append("    <div class='stat-grid'>\n" + "\n".join(cells) + "\n    </div>")
    else:
        parts.append("    <p class='lead'>(no stats provided)</p>")
    return "<div class='slide-inner stat'>\n" + "\n".join(parts) + "\n  </div>"


def render_cards(slide):
    title = esc(_first(slide, "title", "heading", default=""))
    cards = _first(slide, "cards", "items", "columns", "boxes", default=None)
    parts = []
    if title:
        parts.append(f"    <h2>{title}</h2>")
    card_html = []
    for c in _as_list(cards):
        if isinstance(c, dict):
            c_title = esc(_first(c, "title", "heading", "name", default=""))
            c_body = _first(c, "text", "body", "desc", "description", "subtitle", default="")
            inner = ""
            if c_title:
                inner += f"      <h3>{c_title}</h3>\n"
            if c_body:
                inner += f"      <p>{esc(c_body)}</p>\n"
            sub_pts = _first(c, "points", "items", "bullets", default=None)
            sub_pts = [_text_of(p) for p in _as_list(sub_pts) if _text_of(p).strip()]
            if sub_pts:
                lis = "\n".join(f"        <li>{esc(p)}</li>" for p in sub_pts)
                inner += f"      <ul>\n{lis}\n      </ul>\n"
            card_html.append(f"    <div class='card'>\n{inner}    </div>")
        else:
            card_html.append(f"    <div class='card'><p>{esc(_text_of(c))}</p></div>")
    if card_html:
        parts.append("    <div class='card-grid'>\n" + "\n".join(card_html) + "\n    </div>")
    else:
        parts.append("    <p class='lead'>(no cards provided)</p>")
    return "<div class='slide-inner cards'>\n" + "\n".join(parts) + "\n  </div>"


def render_closing(slide):
    title = esc(_first(slide, "title", "heading", default="Thank you"))
    sub = _first(slide, "subtitle", "sub", "tagline", default="")
    cta = _first(slide, "cta", "call_to_action", "action", default="")
    footer = _first(slide, "footer", "note", "contact", default="")
    parts = [f"    <h1 class='cover-title'>{title}</h1>"]
    if sub:
        parts.append(f"    <p class='cover-sub'>{esc(sub)}</p>")
    if cta:
        parts.append(f"    <p class='cta'>{esc(cta)}</p>")
    if footer:
        parts.append(f"    <p class='cover-footer'>{esc(footer)}</p>")
    return "<div class='slide-inner cover closing'>\n" + "\n".join(parts) + "\n  </div>"


RENDERERS = {
    "cover": render_cover,
    "title": render_cover,
    "content": render_content,
    "bullets": render_content,
    "text": render_content,
    "stat": render_stat,
    "stats": render_stat,
    "metric": render_stat,
    "cards": render_cards,
    "grid": render_cards,
    "closing": render_closing,
    "thanks": render_closing,
    "end": render_closing,
}


def render_slide(slide, index):
    if not isinstance(slide, dict):
        slide = {"type": "content", "body": _text_of(slide)}
    stype = str(_first(slide, "type", "kind", "layout", default="content")).lower().strip()
    renderer = RENDERERS.get(stype, render_content)
    inner = renderer(slide)
    return f"<section class='slide' id='s{index}' data-type='{esc(stype)}'>\n  {inner}\n</section>"


# ----------------------------------------------------------------------------
# page shell (design owned here: dark theme, gold accent, RTL, scroll-snap)
# ----------------------------------------------------------------------------
CSS = """
:root{
  --bg:#0d0f14; --panel:#141821; --ink:#f4f1e9; --muted:#a7adba;
  --gold:#d4af37; --gold-soft:#e7c86b; --line:rgba(212,175,55,.22);
}
*{box-sizing:border-box;margin:0;padding:0}
html{scroll-behavior:smooth}
body{
  background:var(--bg); color:var(--ink); direction:rtl;
  font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Heebo,Arial,sans-serif;
  -webkit-font-smoothing:antialiased; line-height:1.5;
}
.deck{scroll-snap-type:y mandatory; height:100vh; overflow-y:scroll}
.slide{
  scroll-snap-align:start; min-height:100vh; width:100%;
  display:flex; align-items:center; justify-content:center;
  padding:7vh 8vw; position:relative;
  border-bottom:1px solid var(--line);
}
.slide::before{
  content:""; position:absolute; inset:0; pointer-events:none;
  background:radial-gradient(1100px 520px at 85% -10%, rgba(212,175,55,.10), transparent 60%);
}
.slide-inner{width:100%; max-width:980px; position:relative; z-index:1}
h1.cover-title{font-size:clamp(40px,7vw,84px); line-height:1.05; letter-spacing:-.5px}
.cover-title{
  background:linear-gradient(180deg,var(--ink),var(--gold-soft));
  -webkit-background-clip:text; background-clip:text; color:transparent;
}
.cover-sub{font-size:clamp(18px,2.4vw,26px); color:var(--muted); margin-top:18px; max-width:760px}
.cover-footer{margin-top:42px; color:var(--gold); font-size:15px; letter-spacing:.5px}
.cover.closing .cta{
  margin-top:26px; display:inline-block; padding:12px 22px; border:1px solid var(--gold);
  border-radius:999px; color:var(--gold-soft); font-size:18px;
}
h2{font-size:clamp(28px,4vw,46px); margin-bottom:26px; position:relative; padding-bottom:14px}
h2::after{content:""; position:absolute; bottom:0; right:0; width:74px; height:4px;
  background:linear-gradient(90deg,var(--gold),transparent); border-radius:4px}
p.lead{font-size:clamp(17px,2vw,22px); color:var(--ink); margin-bottom:18px; max-width:820px}
ul.points{list-style:none; display:flex; flex-direction:column; gap:14px; max-width:840px}
ul.points li{
  position:relative; padding-right:30px; font-size:clamp(16px,1.9vw,21px); color:var(--ink);
}
ul.points li::before{
  content:""; position:absolute; right:4px; top:.62em; width:9px; height:9px;
  background:var(--gold); border-radius:2px; transform:rotate(45deg);
}
.stat-grid{display:grid; grid-template-columns:repeat(auto-fit,minmax(180px,1fr)); gap:22px; margin-top:10px}
.stat{background:var(--panel); border:1px solid var(--line); border-radius:16px; padding:30px 24px; text-align:center}
.stat-value{font-size:clamp(34px,5vw,60px); font-weight:800; color:var(--gold-soft); line-height:1}
.stat-label{margin-top:12px; color:var(--muted); font-size:15px}
.card-grid{display:grid; grid-template-columns:repeat(auto-fit,minmax(240px,1fr)); gap:20px; margin-top:8px}
.card{background:var(--panel); border:1px solid var(--line); border-radius:16px; padding:24px}
.card h3{color:var(--gold-soft); font-size:20px; margin-bottom:10px}
.card p{color:var(--ink); font-size:16px}
.card ul{margin-top:10px; padding-right:18px; color:var(--muted); font-size:15px; display:flex; flex-direction:column; gap:6px}
.nav{position:fixed; bottom:18px; left:50%; transform:translateX(-50%); z-index:50;
  display:flex; gap:8px; align-items:center; background:rgba(20,24,33,.85);
  border:1px solid var(--line); border-radius:999px; padding:8px 14px; backdrop-filter:blur(8px)}
.nav button{background:transparent; color:var(--gold-soft); border:0; font-size:20px; cursor:pointer; line-height:1; padding:2px 8px}
.nav button:hover{color:#fff}
.nav .count{color:var(--muted); font-size:13px; min-width:54px; text-align:center}
@media print{
  .deck{height:auto; overflow:visible}
  .slide{min-height:100vh; page-break-after:always; break-after:page; border:0}
  .slide::before{display:none}
  .nav{display:none}
  body{background:#fff; color:#111}
  .cover-title{color:#111; -webkit-text-fill-color:#111}
  .stat,.card{border-color:#ddd}
}
"""

JS = """
(function(){
  var slides = Array.prototype.slice.call(document.querySelectorAll('.slide'));
  var deck = document.querySelector('.deck');
  var counter = document.getElementById('navcount');
  function current(){
    var top = deck.scrollTop, best = 0, bestd = Infinity;
    slides.forEach(function(s,i){
      var d = Math.abs(s.offsetTop - top);
      if(d < bestd){bestd = d; best = i;}
    });
    return best;
  }
  function go(i){
    i = Math.max(0, Math.min(slides.length-1, i));
    slides[i].scrollIntoView({behavior:'smooth'});
  }
  function refresh(){ if(counter) counter.textContent = (current()+1)+' / '+slides.length; }
  document.getElementById('prev').addEventListener('click', function(){ go(current()-1); });
  document.getElementById('next').addEventListener('click', function(){ go(current()+1); });
  document.addEventListener('keydown', function(e){
    if(e.key==='ArrowDown'||e.key==='ArrowRight'||e.key==='PageDown'||e.key===' '){ e.preventDefault(); go(current()+1); }
    if(e.key==='ArrowUp'||e.key==='ArrowLeft'||e.key==='PageUp'){ e.preventDefault(); go(current()-1); }
    if(e.key==='Home'){ go(0); } if(e.key==='End'){ go(slides.length-1); }
  });
  deck.addEventListener('scroll', refresh);
  refresh();
})();
"""


def build_html(title, slides):
    sections = "\n".join(render_slide(s, i) for i, s in enumerate(slides))
    nav = (
        "<div class='nav'>"
        "<button id='prev' aria-label='previous slide'>&#8594;</button>"
        "<span class='count' id='navcount'></span>"
        "<button id='next' aria-label='next slide'>&#8592;</button>"
        "</div>"
    )
    return f"""<!doctype html>
<html lang="he" dir="rtl">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(title)}</title>
<style>{CSS}</style>
</head>
<body>
<main class="deck">
{sections}
</main>
{nav}
<script>{JS}</script>
</body>
</html>
"""


def load_input(args):
    if args.slides and args.slides != "-":
        raw = Path(args.slides).read_text(encoding="utf-8")
    else:
        raw = sys.stdin.read()
    if not raw.strip():
        raise ValueError("no input: pass --slides FILE or pipe JSON on stdin")
    data = json.loads(raw)
    title = args.title
    if isinstance(data, dict):
        slides = _first(data, "slides", "deck", "pages", default=None)
        if slides is None:
            # a single slide object was passed
            slides = [data]
        if not title:
            title = _first(data, "title", "name", default=None)
    elif isinstance(data, list):
        slides = data
    else:
        raise ValueError("input must be a JSON list of slides or an object with a 'slides' list")
    slides = _as_list(slides)
    if not slides:
        raise ValueError("no slides found in input")
    return (title or "Deck"), slides


def main(argv=None):
    p = argparse.ArgumentParser(description="Build a self-contained HTML deck from JSON slides.")
    p.add_argument("--slides", "-s", default="-", help="path to slides JSON, or - for stdin (default)")
    p.add_argument("--out", "-o", required=True, help="output .html path")
    p.add_argument("--title", "-t", default="", help="deck title (overrides title in JSON)")
    args = p.parse_args(argv)
    try:
        title, slides = load_input(args)
        out_path = Path(args.out)
        if out_path.parent and not out_path.parent.exists():
            out_path.parent.mkdir(parents=True, exist_ok=True)
        html_str = build_html(title, slides)
        out_path.write_text(html_str, encoding="utf-8")
        print(json.dumps({
            "ok": True,
            "out": str(out_path),
            "slides": len(slides),
            "bytes": len(html_str.encode("utf-8")),
        }))
        return 0
    except Exception as exc:  # noqa: BLE001 - report any failure as JSON
        print(json.dumps({"ok": False, "error": f"{type(exc).__name__}: {exc}"}))
        return 1


if __name__ == "__main__":
    sys.exit(main())
