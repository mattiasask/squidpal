<!-- "daylog" remains an internal code symbol (module/namespace/package names and repo folders). User-visible names and the macOS bundle id are Squidpal / io.squidler.squidpal. -->

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/brand/squidpal-lockup-horizontal-on-dark.svg">
    <img alt="Squidpal" src="assets/brand/squidpal-lockup-horizontal.svg" width="340">
  </picture>
</p>

<p align="center"><em>Your day, in a text file.</em></p>

# Squidpal

**A local, open-source "workday diary" for your own computer.** Squidpal is a
small menu-bar / tray app that records what you see and do on your own machine —
the apps you use, the windows and pages you open, the text on screen and what
you type — and writes it to plain text files in a folder you choose. The point
is to give your own AI assistant durable context about your day: follow-ups,
what you were working on, how things connect.

It runs on **macOS, Windows and Linux**, entirely locally. It makes **no network
requests**. Secrets are stripped out before anything is written to disk.

> **Status:** early prototype, in alpha testing. Expect rough edges.
> (User-visible names, the macOS bundle id `io.squidler.squidpal`, and the app/
> binary names are all Squidpal. `daylog` lingers only as an internal code symbol —
> the Swift module, the C# namespace, the Python package and the repo's source
> folders — which can be renamed in a later pass without any user-facing effect.)

---

## ⚠️ Read this before you use it

Squidpal is a **screen-activity recorder**. Please understand what that means:

- **It captures almost everything you look at and type** — emails, chats, web
  pages, documents — **including messages other people send you.** Those people did not choose to be recorded.
- **It is your responsibility** to use this lawfully and ethically. Recording
  other people's communications may have legal implications where you live, and
  may breach the terms of services you use. Squidpal is a personal tool for
  logging *your own* activity on *your own* device; it is not for monitoring
  anyone else.
- **Everything stays on your computer**, in the folder you pick. Squidpal never
  uploads anything. If you choose a synced folder (iCloud, OneDrive, Google
  Drive, Dropbox), the files go wherever that folder syncs — think about that.
- **Secret redaction is best-effort, not a guarantee.** Squidpal never reads
  password fields or password managers, and it masks common secret formats
  (API keys, card numbers, national ID numbers, one-time codes) before writing.
  But it is pattern-based and *will* miss things. Treat the log files as
  sensitive.
- The app always shows clearly in the menu bar / tray whether it is **recording
  or paused**, and you can pause it at any time.

See [docs/PRIVACY.md](docs/PRIVACY.md) for the full picture.

---

## How it works

Each platform has its own reader for the OS accessibility layer — the same
technology screen readers use — plus a shared design for redaction and the
output format:

```
          ┌──────────────┐   ┌──────────────┐   ┌──────────────┐
  macOS   │ Accessibility│   │              │   │              │
  Windows │ UI Automation│──▶│  Redactor    │──▶│  JSONL day   │
  Linux   │   AT-SPI     │   │ (strip secrets)  │   files       │
          └──────────────┘   └──────────────┘   └──────────────┘
           read active window   same rules on      one line per
           text / focus / URL   every platform     event, append-only
```

The **redaction rules are identical across all three platforms** and are tested
against one shared set of fixtures ([`shared/redaction-fixtures.json`](shared/redaction-fixtures.json)),
so masking cannot silently drift between macOS, Windows and Linux.

- **What gets captured, and the JSONL schema:** [docs/FILE_FORMAT.md](docs/FILE_FORMAT.md)
- **How redaction works and its limits:** [docs/REDACTION.md](docs/REDACTION.md)

## Platforms

| Platform | Reads via | UI | Language | Notes |
|----------|-----------|----|----------|-------|
| macOS 14+ | Accessibility API (AXUIElement) | Menu-bar (SwiftUI) | Swift | Needs Accessibility permission. |
| Windows 10/11 | UI Automation (FlaUI) | System tray (WinForms) | C# / .NET 8 | No permission prompt; Chrome/Edge read best. |
| Linux | AT-SPI (pyatspi) | AppIndicator tray | Python / GTK 3 | Works under X11 and Wayland. GNOME needs the AppIndicator extension. |

Each has its own build and run instructions:

- [macOS](macos/README.md)
- [Windows](windows/README.md)
- [Linux](linux/README.md)

## Quick start

The fastest way to see something real is the redaction self-test — it needs no
GUI and no accessibility permissions:

```bash
# Linux / macOS (Python 3):
python3 linux/selftest.py

# Windows / anywhere with .NET 8:
dotnet run --project windows/src/DayLog.SelfTest -c Release -- shared/redaction-fixtures.json

# macOS, with the Swift toolchain:
cd macos && ./build.sh test
```

All three run the same cases from `shared/redaction-fixtures.json` and should
report the same result.

Then build the app for your platform from its README above.

## Repository layout

```
squidpal/
├── macos/      Swift package — menu-bar app + redactor core + tests
├── windows/    .NET 8 solution — tray app + core + self-test
├── linux/      Python package — tray app + core + self-test
├── shared/     redaction-fixtures.json — the one source of truth for masking
├── docs/       file format, redaction, privacy
└── .github/    CI (runs all three test suites) and templates
```

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). The golden
rule: **any change to redaction must keep all platforms passing the shared
fixtures, and new masking behavior needs a new fixture.**

## Security

To report a vulnerability or a case where Squidpal writes a secret it should have
masked, see [SECURITY.md](SECURITY.md). Please don't open a public issue with a
real secret in it.

## License

[MIT](LICENSE) © 2026 Squidler AB.
