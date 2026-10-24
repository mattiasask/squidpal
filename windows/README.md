# Squidpal — Windows

System-tray app for Windows 10/11 that logs your workday to a local folder, one
JSONL file per day. Reads window content through **UI Automation** (via FlaUI).
No network requests.

This is the Windows implementation. For what it captures, the file format and
the privacy picture, see the [top-level docs](../README.md).

## Build & run

Requires the [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0).
Build on Windows.

```powershell
.\build.ps1 test     # run the redaction self-test
.\build.ps1 run      # build and run the app locally
.\build.ps1 dist     # single-file .exe for x64 + arm64, zipped with the tester guide
```

The published `.exe` is self-contained, so the tester needs no .NET install.

## Project layout

- `src/DayLog.Core` — cross-platform core: `Redactor`, `LogWriter`, `LineDedup`.
  No external dependencies.
- `src/DayLog.SelfTest` — runs the shared cases from `../shared/redaction-fixtures.json`.
- `src/DayLog.Win` — WinForms tray app: `UiaReader` (UI Automation), `Recorder`
  (tick loop), `TrayIcon` (the mark drawn with GDI+), `Program` (menu, clipboard,
  lock).

## Redaction

Same layers as the other platforms (`DayLog.Core/Redactor.cs`): password fields
(UIA `IsPassword`) and password managers are never read; concealed clipboards
are skipped; known key formats, PEM, `key=value`, URL credentials, card numbers
(Luhn), national ID numbers and one-time codes are masked; a final entropy pass
catches long random tokens. See [docs/REDACTION.md](../docs/REDACTION.md).

## Known limitations

- Firefox rarely exposes the page URL via UI Automation. Chrome and Edge work best.
- Chromium turns on its accessibility tree the first time the app reads its
  window, so the first switch to a Chrome/Edge window can take an extra second.
- Apps that draw their own text (some games, older Win32 apps without UIA) expose
  little or no text.
- Very large windows: the read stops after 3 s or 60,000 nodes.
- The app is unsigned, so Windows SmartScreen warns once on first run. A code
  signing certificate (Authenticode) removes the warning.

> Note: the executable is **Squidpal.exe** and data lives in `%APPDATA%\Squidpal`.
> The C# namespace is still `DayLog` internally (a code symbol only).
