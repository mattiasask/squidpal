"""Build a faithful, human-readable HTML timeline from a day's JSONL files.

Self-contained (inline CSS, no network). Redaction markers [REDACTED:kind] are
rendered as a lock chip, never expanded, so the viewer SEES what was hidden.
Shared design with the macOS/Windows builds.
"""
from __future__ import annotations

import html as _html
import json
import os
import re
import tempfile
from datetime import datetime, date

_RED = re.compile(r"\[REDACTED:([^\]]+)\]")
_TAGS = {"update": "uppdaterade", "scroll": "skrollade",
         "typing": "skrev", "selection": "markerade", "clipboard": "kopierade"}
_WEEKDAYS = ["måndag", "tisdag", "onsdag", "torsdag", "fredag", "lördag", "söndag"]
_MONTHS = ["", "januari", "februari", "mars", "april", "maj", "juni", "juli",
           "augusti", "september", "oktober", "november", "december"]


def _fmt_dur(sec):
    sec = int(round(sec))
    if sec < 60:
        return f"{sec}s"
    m, s = divmod(sec, 60)
    if m < 60:
        return f"{m}m {s}s" if s else f"{m}m"
    h, m = divmod(m, 60)
    return f"{h}t {m}m" if m else f"{h}t"


def _hhmm(ts):
    try:
        return datetime.fromisoformat(ts).strftime("%H:%M")
    except Exception:
        return (ts or "")[11:16]


def _pretty_date(day):
    try:
        d = date.fromisoformat(day)
        s = f"{_WEEKDAYS[d.weekday()]} {d.day} {_MONTHS[d.month]} {d.year}"
        return s[:1].upper() + s[1:]
    except Exception:
        return day


def _text_html(t):
    esc = _html.escape(t, quote=False)
    return _RED.sub(
        lambda m: f'<span class="red" title="dold: {_html.escape(m.group(1))}">🔒 dold</span>',
        esc).replace("\n", "<br>")


def _read_events(files):
    events = []
    for path in files:
        try:
            with open(path, encoding="utf-8") as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        events.append(json.loads(line))
                    except Exception:
                        continue
        except OSError:
            continue
    events.sort(key=lambda e: e.get("ts") or "")
    return events


def _group(events):
    groups = []
    cur = None
    for e in events:
        key = (e.get("app"), e.get("window_title"), e.get("url"))
        if e.get("event") == "focus" or cur is None or key != cur["key"]:
            cur = {"key": key, "ts": e.get("ts"), "app": e.get("app"),
                   "win": e.get("window_title"), "url": e.get("url"),
                   "page": e.get("page_title"), "items": [], "dwell": None, "red": 0}
            groups.append(cur)
        cur["items"].append(e)
        cur["red"] += int(e.get("redactions") or 0)
        if e.get("event") == "leave" and e.get("dwell_seconds"):
            cur["dwell"] = e.get("dwell_seconds")
    return groups


def _group_html(g):
    app = _html.escape(g["app"] or "Okänd app")
    win = _html.escape(g["win"] or "")
    head = [f'<span class="time">{_hhmm(g["ts"])}</span>',
            f'<span class="app">{app}</span>']
    if win:
        head.append(f'<span class="win">{win}</span>')
    if g["dwell"]:
        head.append(f'<span class="dur">· {_fmt_dur(g["dwell"])}</span>')
    if g["red"]:
        head.append(f'<span class="lock" title="{g["red"]} maskeringar i detta block">🔒</span>')

    url_line = ""
    if g["url"]:
        label = _html.escape((g["page"] + " — " if g["page"] else "") + g["url"])
        url_line = f'<div class="url">{label}</div>'

    body = []
    for e in g["items"]:
        t = e.get("text")
        if not t:
            continue
        tag = _TAGS.get(e.get("event"), "")
        tag_html = f'<span class="tag">{tag}</span>' if tag else ""
        body.append(f'<div class="ev">{tag_html}<div class="text">{_text_html(t)}</div></div>')
    body_html = f'<div class="body">{"".join(body)}</div>' if body else ""

    return (f'<section class="card">'
            f'<div class="chead">{"".join(head)}</div>'
            f'{url_line}{body_html}</section>')


_CSS = """
:root{--bg:#f6f3ec;--card:#fffdf8;--ink:#17293b;--muted:#6a7787;--line:#e7e0d3;
--accent:#c2411f;--chip-bg:#efe7db;--chip-ink:#8a6038;--tag-bg:#e9eef2;--tag-ink:#5b6b7c}
@media (prefers-color-scheme:dark){:root{--bg:#0e1a26;--card:#15222f;--ink:#e9eef3;
--muted:#8599ab;--line:#223342;--accent:#e2683f;--chip-bg:#2a2016;--chip-ink:#e0b483;
--tag-bg:#1d2b39;--tag-ink:#8fa3b6}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);
font:15px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Ubuntu,sans-serif}
.wrap{max-width:760px;margin:0 auto;padding:32px 16px 80px}
header{margin-bottom:24px}
h1{font-size:20px;margin:0 0 2px;letter-spacing:.2px}
.date{color:var(--muted)}
.sub{color:var(--muted);font-size:13px;margin-top:6px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;
padding:14px 16px;margin:10px 0;box-shadow:0 1px 2px rgba(0,0,0,.03)}
.chead{display:flex;flex-wrap:wrap;align-items:baseline;gap:8px}
.time{font-variant-numeric:tabular-nums;color:var(--accent);font-weight:600;font-size:13px}
.app{font-weight:650}
.win{color:var(--muted)}
.dur{color:var(--muted);font-size:13px}
.lock{margin-left:auto;font-size:13px}
.url{color:var(--muted);font-size:12.5px;margin-top:3px;word-break:break-all;
font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
.body{margin-top:10px;display:flex;flex-direction:column;gap:8px}
.ev{display:flex;gap:8px;align-items:flex-start}
.tag{flex:none;font-size:11px;text-transform:uppercase;letter-spacing:.4px;
background:var(--tag-bg);color:var(--tag-ink);padding:2px 7px;border-radius:6px;margin-top:2px}
.text{white-space:pre-wrap;word-break:break-word}
.red{background:var(--chip-bg);color:var(--chip-ink);border-radius:5px;
padding:0 6px;font-size:12.5px;white-space:nowrap}
.empty{color:var(--muted);text-align:center;padding:60px 0}
footer{color:var(--muted);font-size:12px;text-align:center;margin-top:30px}
"""


def build_timeline(files, day, out_dir=None):
    events = _read_events(files)
    groups = _group(events)
    total_red = sum(int(e.get("redactions") or 0) for e in events)
    apps = len({e.get("app") for e in events if e.get("app")})

    if groups:
        cards = "".join(_group_html(g) for g in groups)
    else:
        cards = '<div class="empty">Inga poster för idag ännu.</div>'

    gen = datetime.now().strftime("%H:%M")
    doc = (f'<!doctype html><html lang="sv"><head><meta charset="utf-8">'
           f'<meta name="viewport" content="width=device-width,initial-scale=1">'
           f'<title>Squidpal — {_html.escape(day)}</title><style>{_CSS}</style></head>'
           f'<body><div class="wrap"><header><h1>Squidpal</h1>'
           f'<div class="date">{_html.escape(_pretty_date(day))}</div>'
           f'<div class="sub">{len(events)} poster · {total_red} maskeringar · {apps} appar</div>'
           f'</header><main>{cards}</main>'
           f'<footer>Genererad {gen} · all data stannar lokalt på din dator</footer>'
           f'</div></body></html>')

    out_dir = out_dir or tempfile.gettempdir()
    path = os.path.join(out_dir, f"squidpal-timeline-{day}.html")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(doc)
    return path
