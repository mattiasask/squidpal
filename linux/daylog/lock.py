"""Screen-lock detection. Best effort: subscribes to the GNOME and freedesktop
ScreenSaver ActiveChanged signals and to logind session Lock/Unlock. If none is
available (some minimal setups), locked stays False and recording continues."""
from __future__ import annotations

from gi.repository import Gio, GLib


class LockWatcher:
    def __init__(self):
        self.locked = False
        self._subs = []
        try:
            self._bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        except Exception:
            self._bus = None
        try:
            self._system = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
        except Exception:
            self._system = None
        self._subscribe()

    def _subscribe(self):
        # Session bus: GNOME + freedesktop screensavers emit ActiveChanged(bool).
        for iface in ("org.gnome.ScreenSaver", "org.freedesktop.ScreenSaver"):
            self._sub(self._bus, iface, iface, "ActiveChanged", self._on_active)
        # System bus: logind emits Lock()/Unlock() on the session object.
        self._sub(self._system, "org.freedesktop.login1", "org.freedesktop.login1.Session",
                  "Lock", lambda *_: self._set(True))
        self._sub(self._system, "org.freedesktop.login1", "org.freedesktop.login1.Session",
                  "Unlock", lambda *_: self._set(False))

    def _sub(self, bus, sender, iface, signal, cb):
        if bus is None:
            return
        try:
            sid = bus.signal_subscribe(sender, iface, signal, None, None,
                                       Gio.DBusSignalFlags.NONE, cb)
            self._subs.append((bus, sid))
        except Exception:
            pass

    def _on_active(self, conn, sender, path, iface, signal, params):
        try:
            self._set(bool(params.get_child_value(0).get_boolean()))
        except Exception:
            pass

    def _set(self, value: bool):
        self.locked = value
