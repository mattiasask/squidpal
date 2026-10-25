# File format

Squidpal writes one **JSONL** file per day to the folder you choose:
`YYYY-MM-DD.jsonl`, continuing in `YYYY-MM-DD-2.jsonl`, `-3`, … once a file
passes 50 MB (so cloud-sync clients stay happy).

- One JSON object per line. Lines are only ever **appended**, never rewritten.
- Each line is written with a single write and `fsync`'d, so a sync client never
  sees a half-written line.
- Encoding is UTF-8; non-ASCII text (å, ä, ö, …) is written as-is.

The format is identical on macOS, Windows and Linux.

## Fields

| Field | Type | Meaning |
|-------|------|---------|
| `ts` | string | ISO 8601 timestamp with timezone offset, e.g. `2026-10-24T11:17:03.123+02:00` |
| `event` | string | One of `focus`, `update`, `scroll`, `typing`, `selection`, `clipboard`, `leave` |
| `app` | string\|null | Human-readable application name |
| `bundle_id` | string\|null | Platform app identifier (macOS bundle id, Windows executable name, Linux app name) |
| `window_title` | string\|null | Active window title |
| `url` | string\|null | Current page URL, for browser windows |
| `page_title` | string\|null | Page title, for browser windows |
| `text` | string\|null | Captured text (see "new lines only" below) |
| `redactions` | number | How many values were masked in this record |
| `redaction_kinds` | object | Present only when something was masked: `{ "api_key": 2 }`. **Never contains the values**, only the kind and count. |
| `dwell_seconds` | number\|null | Only on `leave`: how long that window/page was focused |

## Events

- **`focus`** — a new app, window, tab or URL became active. Carries the full
  readable text of the window the first time it's seen.
- **`update`** — the active window's text changed (checked about every 10 s).
- **`scroll`** — new text appeared after scrolling (where the platform can
  detect scroll).
- **`typing`** — the value of the focused field, written once it has been stable
  for ~2 s or when focus moves away.
- **`selection`** — text you selected.
- **`clipboard`** — text you copied (concealed/password-manager clipboards are
  skipped).
- **`leave`** — you left a window/page; carries `dwell_seconds`.

## "New lines only"

`text` contains only lines **not already written today for that same app**.
Revisiting your inbox logs just what's new; a long terminal scrollback is logged
once. Records with nothing new have `text: null`, and `update`/`scroll` with
nothing new aren't written at all. This memory resets at midnight, when you
change the folder, when you delete the day's file, and on restart (after a
restart, everything is written once more).

## Text prefixes

Within `text`, lines read from parts of the active app other than its main
content are tagged with a prefix so an assistant can tell them apart:

- `[menu] …` — the app's menu-bar titles (macOS).
- `[window] …` — window-chrome / toolbar text around the main content (macOS).

Lines with no prefix are the window's own content. These prefixes are in
English on every platform.

## Self-recording is excluded

A window that is showing one of Squidpal's own day files (the filename appears in
the title, or the document lives in the log folder) is logged with only
`focus`/`leave`, no text. Lines that look like Squidpal's own JSONL records are
filtered out everywhere, so viewing or `tail`-ing a log in a terminal doesn't
record itself.

## Example

```json
{"ts":"2026-10-24T11:17:03.123+02:00","event":"focus","app":"Chrome","bundle_id":"com.google.Chrome","window_title":"Inbox","url":"https://mail.example.com/","page_title":"Inbox","text":"Note from a colleague\nAPI key [REDACTED:api_key] in the email","redactions":1,"redaction_kinds":{"api_key":1},"dwell_seconds":null}
{"ts":"2026-10-24T11:19:41.900+02:00","event":"leave","app":"Chrome","bundle_id":"com.google.Chrome","window_title":"Inbox","url":"https://mail.example.com/","page_title":"Inbox","text":null,"redactions":0,"dwell_seconds":158.8}
```
