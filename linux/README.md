# Squidpal — Linux

Tray app for Linux that logs your workday to a local folder, one JSONL file per
day. Reads window content through **AT-SPI** (the accessibility bus), which is
D-Bus based and works under both X11 and Wayland. No network requests.

This is the Linux implementation. For what it captures, the file format and the
privacy picture, see the [top-level docs](../README.md).

## Install & run

```bash
./install.sh         # installs system dependencies (apt or zypper) + autostart
~/.local/bin/squidpal  # start
```

Test the redaction without installing any GUI dependencies:

```bash
python3 selftest.py  # runs the shared cases (should report 72 passed)
```

Dependencies (installed by `install.sh`): `python3-gi`, `python3-pyatspi`,
`at-spi2-core`, the gir/typelib packages for Atspi, Gtk 3.0 and
AyatanaAppIndicator3, and `python3-regex`. The only pure-Python dependency is
`regex`.

## Project layout

- `daylog/redactor.py` — masking. Shares fixtures with macOS/Windows.
- `daylog/logwriter.py`, `daylog/dedup.py` — JSONL writing; new-lines-only; skip own log.
- `daylog/atspi_reader.py` — AT-SPI: active window, window text, focused field,
  password-field skip, browser URL.
- `daylog/recorder.py` — tick loop (on the GLib main loop; AT-SPI calls aren't
  thread-safe).
- `daylog/clipboard.py`, `daylog/lock.py` — clipboard (Gtk.Clipboard) and screen
  lock (ScreenSaver / logind).
- `daylog/app.py` — tray icon (AppIndicator), menu, folder picker.

## Desktop environment notes

- **GNOME (Ubuntu's default)** does not show app tray icons without the
  *AppIndicator and KStatusNotifierItem Support* extension. `install.sh` prints
  how to install and enable it. The app still runs without it — just with no icon.
- **KDE Plasma (common on openSUSE)** works out of the box.
- **Wayland:** AT-SPI reading works, but global scroll events aren't available,
  so new text after scrolling is caught by the 10-second check rather than
  immediately on scroll.
- GTK apps export their content to AT-SPI when a client is present; `install.sh`
  turns on `toolkit-accessibility`. Chromium may need
  `--force-renderer-accessibility` if its content doesn't appear.

## Known limitations

- Apps that draw their own text (some games, some Electron/Qt apps without
  accessibility) expose little or no text.
- Firefox often exposes the URL via AT-SPI, unlike on Windows, but it varies by
  version.
- Very large windows: the read stops after 3 s or 60,000 nodes.

## Uninstall

Quit from the menu, then remove `~/.config/autostart/daylog.desktop` and
`~/.local/bin/squidpal`. Day files stay in your folder. Config is in
`~/.config/squidpal`, counters in `~/.local/state/squidpal`.

> Note: the launcher is `squidpal` (with a `daylog` symlink for one release) and
> config lives in `~/.config/squidpal`. The Python package is still imported as
> `daylog` internally (a code symbol only).
