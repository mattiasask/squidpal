"""Tick loop. Port of the macOS/Windows recorder, driven on the GLib main loop
(pyatspi's synchronous queries need a running GLib loop and are not thread-safe,
so unlike the other platforms the reads happen on the main thread; each read is
budgeted to 3 s / 60 000 nodes so the menu stays responsive)."""
from __future__ import annotations

import hashlib
import os
import re
import time
from dataclasses import dataclass
from datetime import datetime

import pyatspi

from . import redactor
from .atspi_reader import AtspiReader, BROWSER_HINTS, _name, _role, _safe, _has_state
from .dedup import LineDedup
from .logwriter import LogWriter, LogEvent, day_string, day_files


@dataclass
class DayStats:
    day: str
    entries: int
    redactions: int
    bytes: int


# Own day files, and the timeline view of them (which would otherwise be
# re-recorded under the browser).
_DAY_FILE_RE = re.compile(r"\d{4}-\d{2}-\d{2}(?:-\d+)?\.jsonl|squidpal-timeline-\d{4}-\d{2}-\d{2}\.html|^Squidpal — \d{4}-\d{2}-\d{2}")


class Recorder:
    def __init__(self):
        self.reader = AtspiReader()
        self.writer: LogWriter | None = None
        self.on_stats = None
        self.on_error = None

        self._current_key: str | None = None
        self._current_ctx: dict | None = None
        self._current_since = time.monotonic()
        self._last_text_hash: str | None = None
        self._last_text_check = 0.0
        self._last_scroll_handled: float | None = None

        self._focused = None
        self._field_value: str | None = None
        self._field_changed_at = 0.0
        self._field_pending = False
        self._last_typing_hash: str | None = None
        self._selection_candidate: str | None = None
        self._last_selection: str | None = None

        self._dedup = LineDedup()
        self._stats = DayStats(day_string(), 0, 0, 0)
        self._state_dir = os.path.join(
            os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")), "squidpal")

    # ---- stats persistence (survives restart)

    def _counter_path(self, day):
        return os.path.join(self._state_dir, f"stats-{day}.json")

    def load_stats(self):
        import json
        day = day_string()
        entries = redactions = 0
        try:
            with open(self._counter_path(day)) as f:
                d = json.load(f)
                entries, redactions = d.get("entries", 0), d.get("redactions", 0)
        except Exception:
            pass
        self._dedup.reset()
        self._stats = DayStats(day, entries, redactions, self._today_bytes())
        self._emit_stats()

    def _save_counters(self):
        import json
        try:
            os.makedirs(self._state_dir, exist_ok=True)
            with open(self._counter_path(self._stats.day), "w") as f:
                json.dump({"entries": self._stats.entries, "redactions": self._stats.redactions}, f)
        except Exception:
            pass

    def _emit_stats(self):
        if self.on_stats:
            self.on_stats(self._stats)

    # ---- main tick (called on the GLib main loop)

    def tick(self, active: bool, locked: bool, clipboard_text: str | None):
        now = time.monotonic()
        if self._stats.day != day_string():
            self.load_stats()

        if not active or locked:
            self._close_current()
            return

        app, frame = self.reader.active_window()
        if frame is None:
            self._close_current()
            return

        app_name = self.reader.app_name(app) or _name(frame)
        app_id = (app_name or "").lower()
        if app_id.startswith(("daylog", "squidpal")) or app_name in ("DayLog", "Squidpal"):
            return  # never record ourselves

        blocked = redactor.is_blocked_app(app_id, app_name)
        is_browser = any(h in app_id for h in BROWSER_HINTS)

        title = _name(frame)
        url = page_title = None
        if not blocked and is_browser:
            url = self.reader.browser_url(frame)
            page_title = title

        ctx = {"app": app_name, "exe": app_id, "title": title, "url": url, "page_title": page_title}
        key = f"{app_id}|{title}|{url}"

        self_view = (not blocked) and self._is_log_view(ctx)
        textless = blocked or self_view

        if self._current_key != key:
            self._close_current()
            self._current_key = key
            self._current_ctx = ctx
            self._current_since = now
            text = None
            if not textless:
                snap = self.reader.window_text(frame)
                text = self._dedup.new_lines(snap.text, app_id)
                self._last_text_hash = _hash(snap.text)
            else:
                self._last_text_hash = None
            self._last_text_check = now
            self._emit("focus", ctx, text, blocked)
            self._reset_field()
        elif not textless:
            scroll_due = False  # global scroll events are unavailable under Wayland; rely on the 10 s check
            if now - self._last_text_check >= 10:
                snap = self.reader.window_text(frame)
                h = _hash(snap.text)
                if h != self._last_text_hash:
                    added = self._dedup.new_lines(snap.text, app_id)
                    if added:
                        self._emit("update", ctx, added, False)
                    self._last_text_hash = h
                self._last_text_check = now

        if not textless:
            self._track_focused(frame, ctx, now)
        else:
            self._reset_field()

        if not textless and clipboard_text and not LineDedup.looks_like_own_log(clipboard_text):
            self._emit("clipboard", ctx, clipboard_text, False)

    # ---- public ops

    def pause_or_stop(self):
        self._close_current()

    def delete_today(self):
        if not self.writer:
            return
        day = day_string()
        for f in day_files(self.writer.folder, day):
            try:
                os.remove(f)
            except OSError:
                pass
        try:
            os.remove(self._counter_path(day))
        except OSError:
            pass
        self._current_key = None
        self._last_text_hash = self._last_typing_hash = self._last_selection = None
        self._dedup.reset()
        self.load_stats()

    def today_file(self):
        if not self.writer:
            return None
        files = day_files(self.writer.folder, day_string())
        return files[-1] if files else None

    # ---- internals

    def _close_current(self):
        self._flush_typing(force=True)
        if self._current_ctx is None:
            return
        c = self._current_ctx
        blocked = redactor.is_blocked_app(c["exe"], c["app"])
        self._emit("leave", c, None, blocked, dwell=time.monotonic() - self._current_since)
        self._current_key = None
        self._current_ctx = None
        self._last_text_hash = None

    def _reset_field(self):
        self._focused = None
        self._field_value = None
        self._field_pending = False
        self._selection_candidate = None

    def _track_focused(self, frame, ctx, now):
        el = self.reader.focused_element(frame)
        if el is None:
            return
        role = _role(el)
        if self.reader.is_sensitive(el, role):
            self._flush_typing(True)
            self._reset_field()
            return
        is_input = role in (pyatspi.ROLE_ENTRY, pyatspi.ROLE_TEXT, pyatspi.ROLE_DOCUMENT_WEB)
        value = None
        try:
            value = el.queryText().getText(0, -1)
        except Exception:
            value = _name(el)

        if self._focused is not None and not _same(self._focused, el):
            self._flush_typing(True)
            self._reset_field()
        if self._focused is None:
            self._focused = el
            self._field_value = value

        if is_input and value is not None and value != self._field_value:
            self._field_value = value
            self._field_changed_at = now
            self._field_pending = True
        if self._field_pending and now - self._field_changed_at >= 2:
            self._flush_typing(False)

        sel = None
        try:
            t = el.queryText()
            if t.getNSelections() > 0:
                start, end = t.getSelection(0)
                sel = t.getText(start, end).strip()
        except Exception:
            sel = None
        if sel:
            if sel == self._selection_candidate and sel != self._last_selection:
                self._emit("selection", ctx, sel, False)
                self._last_selection = sel
            self._selection_candidate = sel
        else:
            self._selection_candidate = None

    def _flush_typing(self, force):
        if not self._field_pending or self._current_ctx is None or self._field_value is None:
            return
        self._field_pending = False
        value = self._field_value
        h = _hash(value)
        if h == self._last_typing_hash or not value.strip():
            return
        self._last_typing_hash = h
        added = self._dedup.new_lines(value, self._current_ctx["exe"])
        if added:
            self._emit("typing", self._current_ctx, added, False)

    def _emit(self, event, ctx, text, blocked, dwell=None):
        if not self.writer:
            return
        e = LogEvent(ts=datetime.now(), event=event, app=ctx["app"], bundle_id=ctx["exe"], dwell_seconds=dwell)
        n = 0

        def clean(s):
            nonlocal n
            if not s:
                return None
            r = redactor.redact(s)
            n += r.count
            for k in r.kinds:
                e.redaction_kinds[k] = e.redaction_kinds.get(k, 0) + 1
            return r.text

        if not blocked:
            e.window_title = clean(ctx["title"])
            e.url = clean(ctx["url"])
            e.page_title = clean(ctx["page_title"])
            e.text = clean(text)
        e.redactions = n
        try:
            nbytes = self.writer.append(e)
            self._stats = DayStats(self._stats.day, self._stats.entries + 1,
                                   self._stats.redactions + n, self._stats.bytes + nbytes)
            self._save_counters()
            self._emit_stats()
        except Exception as ex:
            if self.on_error:
                self.on_error(f"Kunde inte skriva: {ex}")

    def _is_log_view(self, ctx):
        for s in (ctx.get("title"), ctx.get("page_title"), ctx.get("url")):
            if s and _DAY_FILE_RE.search(s):
                return True
        return False

    def _today_bytes(self):
        if not self.writer:
            return 0
        from .logwriter import _size
        return sum(_size(f) for f in day_files(self.writer.folder, day_string()))


def _hash(s: str) -> str:
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


def _same(a, b) -> bool:
    # pyatspi Accessible implements identity equality.
    try:
        return a == b
    except Exception:
        return False
