"""Clipboard watcher built on Gtk.Clipboard, which works under both X11 and
Wayland. Password managers mark their clipboard with a hint target
(x-kde-passwordManagerHint on KDE/Plasma); such contents are never captured.

The synchronous wait_for_* reads happen in drain() (called from the 1 s timer on
the main loop), not inside the owner-change signal handler, so a slow or flaky
clipboard owner can't stall or re-enter the loop from within the signal."""
from __future__ import annotations

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, Gdk

from .redactor import is_concealed_clipboard

_CONCEALED_TARGET_HINTS = ("x-kde-passwordmanagerhint", "concealed", "org.nspasteboard.concealedtype")


class ClipboardWatcher:
    def __init__(self):
        self._clip = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)
        self._dirty = False
        self._clip.connect("owner-change", self._on_change)

    def _on_change(self, clipboard, event):
        # Only flag it; the actual (synchronous) read happens in drain().
        self._dirty = True

    def drain(self) -> tuple[bool, str | None]:
        """Returns (changed_since_last_drain, text-or-None). Concealed or
        non-text clipboards return (True, None)."""
        if not self._dirty:
            return False, None
        self._dirty = False
        text = None
        try:
            ok, atoms = self._clip.wait_for_targets()
            concealed = False
            if ok and atoms:
                names = [a.name().lower() for a in atoms]
                concealed = is_concealed_clipboard(names) or any(
                    h in n for n in names for h in _CONCEALED_TARGET_HINTS)
            if not concealed:
                text = self._clip.wait_for_text()
        except Exception:
            text = None
        return True, text
