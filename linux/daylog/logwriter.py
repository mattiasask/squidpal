"""Append-only JSONL day files. Same fields and format as the macOS/Windows
versions: each line written and fsync'd in one go, parts roll at 50 MB."""
from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from datetime import datetime


@dataclass
class LogEvent:
    ts: datetime
    event: str                      # focus, update, scroll, typing, selection, clipboard, leave
    app: str | None = None
    bundle_id: str | None = None    # application name on Linux (e.g. "google-chrome")
    window_title: str | None = None
    url: str | None = None
    page_title: str | None = None
    text: str | None = None
    redactions: int = 0
    redaction_kinds: dict[str, int] = field(default_factory=dict)
    dwell_seconds: float | None = None


MAX_FILE_BYTES = 50 * 1024 * 1024


def day_string(dt: datetime | None = None) -> str:
    return (dt or datetime.now()).strftime("%Y-%m-%d")


def part_path(folder: str, day: str, part: int) -> str:
    name = f"{day}.jsonl" if part == 1 else f"{day}-{part}.jsonl"
    return os.path.join(folder, name)


def day_files(folder: str, day: str) -> list[str]:
    out = []
    part = 1
    while True:
        p = part_path(folder, day, part)
        if not os.path.exists(p):
            break
        out.append(p)
        part += 1
    return out


def _size(path: str) -> int:
    try:
        return os.path.getsize(path)
    except OSError:
        return 0


class LogWriter:
    def __init__(self, folder: str):
        self.folder = folder

    def _current_file(self, day: str) -> str:
        existing = day_files(self.folder, day)
        if not existing:
            return part_path(self.folder, day, 1)
        last = existing[-1]
        if _size(last) >= MAX_FILE_BYTES:
            return part_path(self.folder, day, len(existing) + 1)
        return last

    def append(self, e: LogEvent) -> int:
        """Writes one JSONL line, flushed to disk. Returns bytes written."""
        line = self._serialize(e) + "\n"
        data = line.encode("utf-8")
        path = self._current_file(day_string(e.ts))
        # O_APPEND keeps concurrent writes line-atomic; fsync so a sync client
        # never sees a half-written line.
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        try:
            os.write(fd, data)
            os.fsync(fd)
        finally:
            os.close(fd)
        return len(data)

    @staticmethod
    def _serialize(e: LogEvent) -> str:
        # ISO 8601 with timezone offset, matching the other platforms.
        ts = e.ts.astimezone().isoformat(timespec="milliseconds")
        parts = [
            ("ts", ts),
            ("event", e.event),
            ("app", e.app),
            ("bundle_id", e.bundle_id),
            ("window_title", e.window_title),
            ("url", e.url),
            ("page_title", e.page_title),
            ("text", e.text),
        ]
        chunks = [f"{json.dumps(k)}:{json.dumps(v, ensure_ascii=False)}" for k, v in parts]
        chunks.append(f'"redactions":{e.redactions}')
        if e.redaction_kinds:
            kinds = ",".join(f"{json.dumps(k)}:{v}" for k, v in sorted(e.redaction_kinds.items()))
            chunks.append(f'"redaction_kinds":{{{kinds}}}')
        chunks.append('"dwell_seconds":' + (f"{e.dwell_seconds:.1f}" if e.dwell_seconds is not None else "null"))
        return "{" + ",".join(chunks) + "}"
