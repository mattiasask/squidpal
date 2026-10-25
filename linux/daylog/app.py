"""DayLog for Linux — tray app. AppIndicator tray + GLib main loop; the recorder
polls AT-SPI once a second on this loop."""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, GLib, Gio

# AppIndicator ships under two names depending on distro.
_AppInd = None
for _name, _ver in (("AyatanaAppIndicator3", "0.1"), ("AppIndicator3", "0.1")):
    try:
        gi.require_version(_name, _ver)
        _AppInd = __import__("gi.repository", fromlist=[_name]).__dict__[_name]
        break
    except (ValueError, ImportError, KeyError):
        continue

from .recorder import Recorder, DayStats
from .clipboard import ClipboardWatcher
from .lock import LockWatcher
from .logwriter import LogWriter, day_string, day_files

ICONS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "icons")
CONFIG_DIR = os.path.join(os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")), "squidpal")
SETTINGS = os.path.join(CONFIG_DIR, "settings.json")


def _load_folder():
    try:
        with open(SETTINGS) as f:
            return json.load(f).get("folder")
    except Exception:
        return None


def _save_folder(path):
    try:
        os.makedirs(CONFIG_DIR, exist_ok=True)
        with open(SETTINGS, "w") as f:
            json.dump({"folder": path}, f)
    except Exception:
        pass


class DayLogApp:
    def __init__(self):
        self.folder = None
        self.pause_mode = "none"          # none | until | indefinite
        self.pause_until = 0.0
        self.stats = DayStats(day_string(), 0, 0, 0)
        self.last_error = None

        self.recorder = Recorder()
        self.recorder.on_stats = self._on_stats
        self.recorder.on_error = self._on_error
        self.clipboard = ClipboardWatcher()
        self.lock = LockWatcher()

        self.menu = Gtk.Menu()
        if _AppInd is not None:
            self.indicator = _AppInd.Indicator.new(
                "squidpal", "squidpal-off", _AppInd.IndicatorCategory.APPLICATION_STATUS)
            self.indicator.set_icon_theme_path(ICONS_DIR)
            self.indicator.set_status(_AppInd.IndicatorStatus.ACTIVE)
            self.indicator.set_menu(self.menu)
        else:
            self.indicator = None
            print("VARNING: AppIndicator saknas – ingen ikon i panelen. "
                  "På GNOME: installera tillägget 'AppIndicator and KStatusNotifierItem Support'.",
                  file=sys.stderr)

        folder = _load_folder()
        if folder and os.path.isdir(folder):
            self._start_writer(folder)
        else:
            self._choose_folder()

        self._rebuild_menu()
        self._refresh_icon()
        GLib.timeout_add_seconds(1, self._tick)

    # ---- state

    @property
    def is_paused(self):
        if self.pause_mode == "indefinite":
            return True
        if self.pause_mode == "until":
            return self.pause_until > time.monotonic()
        return False

    @property
    def is_recording(self):
        return self.folder is not None and not self.is_paused and not self.lock.locked

    def _on_stats(self, s):
        self.stats = s
        self._rebuild_menu()

    def _on_error(self, m):
        self.last_error = m
        self._rebuild_menu()

    # ---- tick

    def _tick(self):
        if self.pause_mode == "until" and self.pause_until <= time.monotonic():
            self.pause_mode = "none"
        changed, clip = self.clipboard.drain()
        clip_text = clip if (changed and self.is_recording) else None
        try:
            self.recorder.tick(self.is_recording, self.lock.locked, clip_text)
        except Exception as ex:
            self.last_error = f"tick: {ex}"
        self._refresh_icon()
        return True  # keep the timeout

    # ---- writer / folder

    def _start_writer(self, folder):
        self.folder = folder
        self.recorder.pause_or_stop()
        self.recorder.writer = LogWriter(folder)
        self.recorder.load_stats()

    def _choose_folder(self):
        dlg = Gtk.FileChooserDialog(
            title="Välj mapp för Squidpal", action=Gtk.FileChooserAction.SELECT_FOLDER)
        dlg.add_buttons("Avbryt", Gtk.ResponseType.CANCEL, "Välj", Gtk.ResponseType.OK)
        dlg.set_current_folder(os.path.expanduser("~"))
        if dlg.run() == Gtk.ResponseType.OK:
            path = dlg.get_filename()
            if path and os.path.isdir(path):
                _save_folder(path)
                self._start_writer(path)
        dlg.destroy()
        self._rebuild_menu()
        self._refresh_icon()

    # ---- menu

    def _status_line(self):
        if self.folder is None:
            return "⚠ Ingen mapp vald – spelar inte in"
        if self.lock.locked:
            return "Skärmen är låst – spelar inte in"
        if self.pause_mode == "indefinite":
            return "⏸ Pausad tills du slår på igen"
        if self.pause_mode == "until" and self.pause_until > time.monotonic():
            mins = int((self.pause_until - time.monotonic()) / 60) + 1
            return f"⏸ Pausad (~{mins} min kvar)"
        return "● Spelar in"

    def _rebuild_menu(self):
        for child in self.menu.get_children():
            self.menu.remove(child)

        def item(label, cb=None, enabled=True):
            mi = Gtk.MenuItem(label=label)
            if cb:
                mi.connect("activate", cb)
            mi.set_sensitive(enabled and cb is not None)
            self.menu.append(mi)
            return mi

        item(self._status_line(), enabled=False)
        self.menu.append(Gtk.SeparatorMenuItem())
        item(f"Idag: {self.stats.entries} poster · {self.stats.redactions} maskeringar", enabled=False)
        item("Filstorlek: " + _bytes(self.stats.bytes), enabled=False)
        if self.last_error:
            item(self.last_error, enabled=False)
        self.menu.append(Gtk.SeparatorMenuItem())

        if self.is_paused:
            item("Slå på inspelning", lambda _: self._resume())
        else:
            pause = Gtk.MenuItem(label="Pausa")
            sub = Gtk.Menu()
            for label, mins in (("15 minuter", 15), ("1 timme", 60), ("Tills jag slår på igen", None)):
                mi = Gtk.MenuItem(label=label)
                mi.connect("activate", lambda _w, m=mins: self._pause(m))
                sub.append(mi)
            pause.set_submenu(sub)
            self.menu.append(pause)

        self.menu.append(Gtk.SeparatorMenuItem())
        item("Visa dagens tidslinje", lambda _: self._show_timeline())
        item("Öppna dagens fil", lambda _: self._open_today())
        item("Visa mappen", lambda _: self._reveal())
        item("Radera dagens fil…", lambda _: self._delete_today())
        item("Välj mapp…" if self.folder is None else "Byt mapp…", lambda _: self._choose_folder())
        if self.folder:
            item(self.folder, enabled=False)
        self.menu.append(Gtk.SeparatorMenuItem())
        item("Avsluta Squidpal", lambda _: self._quit())
        self.menu.show_all()

    def _pause(self, minutes):
        if minutes is None:
            self.pause_mode = "indefinite"
        else:
            self.pause_mode = "until"
            self.pause_until = time.monotonic() + minutes * 60
        self.recorder.pause_or_stop()
        self._rebuild_menu()
        self._refresh_icon()

    def _resume(self):
        self.pause_mode = "none"
        self._rebuild_menu()
        self._refresh_icon()

    def _show_timeline(self):
        if not self.folder:
            return
        files = day_files(self.folder, day_string())
        if not files:
            return
        try:
            from .timeline import build_timeline
            _xdg_open(build_timeline(files, day_string()))
        except Exception:
            pass

    def _open_today(self):
        f = self.recorder.today_file()
        if f:
            _xdg_open(f)

    def _reveal(self):
        if self.folder:
            _xdg_open(self.folder)

    def _delete_today(self):
        dlg = Gtk.MessageDialog(
            message_type=Gtk.MessageType.WARNING, buttons=Gtk.ButtonsType.OK_CANCEL,
            text="Radera dagens fil?")
        dlg.format_secondary_text("Alla poster från idag tas bort permanent från mappen.")
        resp = dlg.run()
        dlg.destroy()
        if resp == Gtk.ResponseType.OK:
            self.recorder.delete_today()

    # ---- icon

    def _refresh_icon(self):
        if self.indicator is None:
            return
        state = "squidpal-recording" if self.is_recording else ("squidpal-off" if self.folder is None else "squidpal-paused")
        desc = {"squidpal-recording": "spelar in", "squidpal-paused": "pausad", "squidpal-off": "ingen mapp vald"}[state]
        self.indicator.set_icon_full(state, "Squidpal – " + desc)

    def _quit(self):
        try:
            self.recorder.pause_or_stop()
        except Exception:
            pass
        Gtk.main_quit()


def _bytes(n):
    for u in ("B", "KB", "MB", "GB"):
        if n < 1024 or u == "GB":
            return f"{n:.1f} {u}" if u != "B" else f"{int(n)} {u}"
        n /= 1024


def _xdg_open(path):
    try:
        subprocess.Popen(["xdg-open", path])
    except Exception:
        pass


def main():
    # Do not record our own process.
    os.environ.setdefault("NO_AT_BRIDGE", "1")
    DayLogApp()
    Gtk.main()


if __name__ == "__main__":
    main()
