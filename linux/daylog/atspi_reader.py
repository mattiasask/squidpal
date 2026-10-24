"""Reads window content through AT-SPI (the Linux accessibility bus), the
counterpart of macOS's Accessibility API and Windows UI Automation. AT-SPI is
D-Bus based, so this works under both X11 and Wayland for apps that export
accessibility (GTK, Qt, and Chromium/Electron once an AT client is present).

Used only from the recorder thread.
"""
from __future__ import annotations

import time

import pyatspi
from . import redactor

# Text-bearing roles.
_TEXT_ROLES = {
    pyatspi.ROLE_TEXT, pyatspi.ROLE_ENTRY, pyatspi.ROLE_PARAGRAPH, pyatspi.ROLE_STATIC,
    pyatspi.ROLE_LABEL, pyatspi.ROLE_HEADING, pyatspi.ROLE_CAPTION,
}
_INPUT_ROLES = {pyatspi.ROLE_ENTRY, pyatspi.ROLE_TEXT, pyatspi.ROLE_PASSWORD_TEXT,
                pyatspi.ROLE_DOCUMENT_WEB, pyatspi.ROLE_DOCUMENT_FRAME}
_LABELLED_ROLES = {
    pyatspi.ROLE_PUSH_BUTTON, pyatspi.ROLE_TOGGLE_BUTTON, pyatspi.ROLE_MENU_ITEM,
    pyatspi.ROLE_CHECK_BOX, pyatspi.ROLE_RADIO_BUTTON, pyatspi.ROLE_LINK,
    pyatspi.ROLE_PAGE_TAB, pyatspi.ROLE_LIST_ITEM, pyatspi.ROLE_TREE_ITEM,
}
_WEB_ROLES = {pyatspi.ROLE_DOCUMENT_WEB, pyatspi.ROLE_DOCUMENT_FRAME}
_SKIP_SUBTREE_ROLES = {pyatspi.ROLE_PASSWORD_TEXT, pyatspi.ROLE_IMAGE, pyatspi.ROLE_ICON}

BROWSER_HINTS = ("chrome", "chromium", "google-chrome", "brave", "microsoft-edge",
                 "edge", "vivaldi", "opera", "firefox", "epiphany")


def _safe(fn, default=None):
    try:
        return fn()
    except Exception:
        return default


def _name(o) -> str | None:
    return _safe(lambda: o.name)


def _role(o):
    return _safe(lambda: o.getRole(), pyatspi.ROLE_UNKNOWN)


def _states(o):
    return _safe(lambda: o.getState(), None)


def _has_state(o, state) -> bool:
    st = _states(o)
    try:
        return bool(st and st.contains(state))
    except Exception:
        return False


def _text_of(o) -> str | None:
    try:
        t = o.queryText()
        return t.getText(0, -1)
    except Exception:
        return None


def _attr(o, key) -> str | None:
    try:
        for a in o.getAttributes():
            k, _, v = a.partition(":")
            if k == key:
                return v
    except Exception:
        pass
    return None


class Snapshot:
    __slots__ = ("text", "truncated")

    def __init__(self, text: str, truncated: bool):
        self.text = text
        self.truncated = truncated


class AtspiReader:
    def desktop(self):
        return _safe(lambda: pyatspi.Registry.getDesktop(0))

    def active_window(self):
        """The frame with STATE_ACTIVE, and its application. Returns (app, frame)
        or (None, None)."""
        desk = self.desktop()
        if not desk:
            return None, None
        for i in range(_safe(lambda: desk.childCount, 0) or 0):
            app = _safe(lambda: desk.getChildAtIndex(i))
            if not app:
                continue
            for j in range(_safe(lambda: app.childCount, 0) or 0):
                frame = _safe(lambda: app.getChildAtIndex(j))
                if frame and _has_state(frame, pyatspi.STATE_ACTIVE):
                    return app, frame
        return None, None

    def app_name(self, app) -> str | None:
        return _name(app)

    def is_sensitive(self, obj, role) -> bool:
        if role == pyatspi.ROLE_PASSWORD_TEXT:
            return True
        if role not in _INPUT_ROLES:
            return False
        names = [_name(obj), _attr(obj, "id"), _attr(obj, "name"),
                 _attr(obj, "placeholder-text"), _safe(lambda: obj.description)]
        return redactor.is_sensitive_field(False, names)

    def focused_element(self, root):
        """Depth-first search for the STATE_FOCUSED descendant (bounded)."""
        stack = [root]
        visited = 0
        while stack and visited < 8000:
            el = stack.pop()
            visited += 1
            if _has_state(el, pyatspi.STATE_FOCUSED):
                return el
            n = _safe(lambda: el.childCount, 0) or 0
            for i in range(min(n, 200)):
                c = _safe(lambda: el.getChildAtIndex(i))
                if c is not None:
                    stack.append(c)
        return None

    def window_text(self, root, time_budget=3.0, node_budget=60_000) -> Snapshot:
        lines: list[str] = []
        last = None
        visited = 0
        deadline = time.monotonic() + time_budget
        truncated = False

        def add(s):
            nonlocal last
            if not s:
                return
            s = s.strip()
            if not s:
                return
            if len(s) > 200_000:
                s = s[:200_000]
            if s != last:
                lines.append(s)
                last = s

        stack = [root]
        while stack:
            el = stack.pop()
            visited += 1
            if visited > node_budget or (visited % 200 == 0 and time.monotonic() > deadline):
                truncated = True
                break
            role = _role(el)
            if role in _SKIP_SUBTREE_ROLES:
                continue
            if role in _TEXT_ROLES:
                add(_text_of(el) or _name(el))
            elif role in _INPUT_ROLES:
                if not self.is_sensitive(el, role):
                    add(_text_of(el) or _name(el))
            elif role in _LABELLED_ROLES:
                add(_name(el))
            n = _safe(lambda: el.childCount, 0) or 0
            # push children in reverse so document order is preserved
            for i in range(min(n, 500) - 1, -1, -1):
                c = _safe(lambda: el.getChildAtIndex(i))
                if c is not None:
                    stack.append(c)
        return Snapshot("\n".join(lines), truncated)

    def browser_url(self, frame) -> str | None:
        """Current page URL from the web document. Firefox and Chromium both
        expose it via the AtkDocument 'DocURL'/'URI' attribute."""
        doc = self._find_first_role(frame, _WEB_ROLES, max_depth=14)
        if not doc:
            return None
        for key in ("DocURL", "URI", "url"):
            v = None
            try:
                v = doc.queryDocument().getAttributeValue(key)
            except Exception:
                v = _attr(doc, key)
            if v and not v.startswith("about:"):
                return v
        return None

    def _find_first_role(self, root, roles, max_depth):
        level = [root]
        for _ in range(max_depth):
            nxt = []
            for el in level:
                if _role(el) in roles:
                    return el
                n = _safe(lambda: el.childCount, 0) or 0
                for i in range(min(n, 400)):
                    c = _safe(lambda: el.getChildAtIndex(i))
                    if c is not None:
                        nxt.append(c)
                if len(nxt) > 4000:
                    break
            if not nxt:
                break
            level = nxt
        return None
