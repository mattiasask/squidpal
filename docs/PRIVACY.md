# Privacy

Squidpal is a screen-activity recorder. This page is the honest, complete
account of what that means. Please read it before you run it.

## What Squidpal does

- Reads the **active window** on your computer through the OS accessibility layer
  (the same mechanism screen readers use): the app and window, the page URL in
  browsers, the text on screen, the field you're typing in, your selection, and
  your clipboard.
- Masks secrets (see [REDACTION.md](REDACTION.md)) and **appends** the rest to
  plain-text JSONL files in a folder you choose.

## What Squidpal does **not** do

- **No network.** Squidpal makes no network requests. Nothing is uploaded,
  anywhere, to anyone. There is no telemetry and no account.
- **No background spying.** It records only while it is running and shows
  "recording" in the menu bar / tray. It stops when you pause it and when the
  screen is locked.
- **No password fields, no password managers.** Those are never read.

## Where your data lives

In the folder you pick, as files you can open, read, and delete yourself. If you
choose a folder that syncs to the cloud (iCloud, OneDrive, Google Drive,
Dropbox), the files sync wherever that folder goes — that is your choice to make,
so choose deliberately.

Settings and counters live in the standard per-user config location for each OS
(`~/Library/...` / `%APPDATA%\Squidpal` / `~/.config/squidpal`).

## The part that needs your judgment

Squidpal captures **other people's words too** — the emails, messages and chats
other people send you. They didn't opt in.

- Using this may have **legal implications** where you live. Rules on recording
  communications vary by country and context. You are responsible for complying
  with the law that applies to you.
- It may breach the **terms of service** of apps and sites you use.
- It is a tool for logging **your own** activity on **your own** device for your
  **own** assistant. It is not for monitoring employees, family members, or
  anyone else, and the maintainers don't support that use.

If you share log files — with an AI assistant, a colleague, or anyone — remember
they can contain other people's words and anything redaction missed. Read before
you share.

## Your controls

- **Pause** any time (15 min, 1 hour, or until you turn it back on).
- **Delete today's file** from the menu.
- **Change or clear the folder** at any time.
- **Quit** to stop entirely; remove it by deleting the app and its config folder
  (each platform README has the exact steps).

## In short

Squidpal keeps everything on your machine and tries hard not to write secrets.
But it records a lot, including things that aren't only yours to record. Use it
thoughtfully.
