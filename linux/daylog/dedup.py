"""Per-app set of lines already written today, so a revisit to Gmail or a long
terminal scrollback only costs what is new. Also drops lines that are our own
JSONL records (so viewing/tailing the log does not record itself).
Reset at midnight, on folder change, on 'delete today' and on restart."""
from __future__ import annotations

_MAX_PER_APP = 300_000


class LineDedup:
    def __init__(self) -> None:
        self._seen: dict[str, set[int]] = {}

    def reset(self) -> None:
        self._seen.clear()

    def new_lines(self, text: str, app: str | None) -> str | None:
        """Lines of text not yet written today for app (None if none),
        own-log lines removed."""
        key = app or "?"
        seen = self._seen.setdefault(key, set())
        if len(seen) > _MAX_PER_APP:
            seen.clear()
        kept = []
        for raw in text.split("\n"):
            line = raw.strip()
            if not line or self.is_own_log_line(line):
                continue
            h = hash(line)
            if h not in seen:
                seen.add(h)
                kept.append(raw)
        return "\n".join(kept) if kept else None

    @staticmethod
    def is_own_log_line(line: str) -> bool:
        return line.startswith('{"ts":"') or ('"event":"' in line and '"bundle_id":' in line)

    @classmethod
    def looks_like_own_log(cls, text: str) -> bool:
        return any(cls.is_own_log_line(l.strip()) for l in text.split("\n")[:3])
