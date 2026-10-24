"""Secret handling. Port of RedactorCore/Redactor.swift (macOS) and Redactor.cs
(Windows); all three are tested against shared/redaction-fixtures.json so the
rules can't drift.

Uses the third-party ``regex`` module (not stdlib ``re``) for \\p{L}-style
Unicode property escapes, matching ICU/.NET behaviour.

Layers:
  1. is_sensitive_field*  - fields that must never be read.
  2. is_concealed_clipboard - clipboard marked secret by password managers.
  3. is_blocked_app      - password managers: record the app name only.
  4. regex rules         - key formats, PEM, key=value, URL creds, cards, pnr, OTP.
  5. entropy pass        - long random-looking tokens.
"""
from __future__ import annotations

import math
from collections import Counter
from dataclasses import dataclass, field

import regex  # python-regex, for \p{...} Unicode classes

MARKER = "[REDACTED:"


@dataclass
class RedactionOutput:
    text: str
    count: int
    kinds: list[str] = field(default_factory=list)


# ----------------------------------------------------------------- Layer 1

_SUBSTRING_FIELD_WORDS = [
    "password", "passwd", "lösenord", "losenord", "passcode", "secret", "token",
    "säkerhetskod", "sakerhetskod", "pinkod", "engångskod", "engangskod",
]
_BOUNDED_FIELD_WORDS = ["pin", "otp", "2fa", "cvc", "cvv", "cvv2"]
_BOUNDED_FIELD_RE = [regex.compile(r"(?<!\p{L})" + w + r"(?!\p{L})") for w in _BOUNDED_FIELD_WORDS]
_CAMEL_SPLIT = regex.compile(r"(\p{Ll})(\p{Lu})")


def is_sensitive_field_name(raw: str | None) -> bool:
    """True if a label, placeholder, id or name suggests a secret."""
    if not raw:
        return False
    spaced = _CAMEL_SPLIT.sub(r"\1 \2", raw).lower()
    if any(w in spaced for w in _SUBSTRING_FIELD_WORDS):
        return True
    return any(r.search(spaced) for r in _BOUNDED_FIELD_RE)


def is_sensitive_field(is_password: bool, names) -> bool:
    return is_password or any(is_sensitive_field_name(n) for n in names)


# ----------------------------------------------------------------- Layer 2

# AT-SPI / X11 / Wayland and password-manager clipboard hints.
CONCEALED_CLIPBOARD_TYPES = {
    "x-kde-passwordmanagerhint",            # KDE/Plasma convention (value "secret")
    "org.nspasteboard.concealedtype",       # kept so the rule is the same everywhere
    "org.nspasteboard.transienttype",
}


def is_concealed_clipboard(mime_types) -> bool:
    return any(t.lower() in CONCEALED_CLIPBOARD_TYPES for t in mime_types)


# ----------------------------------------------------------------- Layer 3

_BLOCKED_NAME_WORDS = [
    "1password", "bitwarden", "dashlane", "keepass", "lastpass", "nordpass",
    "enpass", "keeper", "roboform", "strongbox", "proton pass",
    "keychain", "nyckelhanteraren", "gnome-keyring", "seahorse",
]


def is_blocked_app(app_id: str | None, name: str | None) -> bool:
    """app_id is the application name from AT-SPI; name is the window/app label."""
    a = (app_id or "").lower()
    n = (name or "").lower()
    if n in ("lösenord", "passwords"):
        return True
    return any(w in a or w in n for w in _BLOCKED_NAME_WORDS)


# ----------------------------------------------------------------- Layer 4

_OTP_CONTEXT = regex.compile(
    r"(?<!\p{L})(?:(?:verifierings|säkerhets|engångs|bekräftelse|inloggnings|login|pass|sms-?)?kod(?:en)?"
    r"|(?:pass)?code|otp|bankid|2fa|verifi\p{L}*|one-time)(?!\p{L})",
    regex.IGNORECASE,
)
_OTP_BEFORE, _OTP_AFTER = 30, 12


def _luhn(digits: str) -> bool:
    if len(digits) < 2 or not digits.isdigit():
        return False
    total = 0
    for i, ch in enumerate(reversed(digits)):
        d = int(ch)
        if i % 2 == 1:
            d *= 2
            if d > 9:
                d -= 9
        total += d
    return total % 10 == 0


def is_personnummer(value: str) -> bool:
    d = "".join(c for c in value if c.isdigit())
    if len(d) not in (10, 12):
        return False
    ten = d[-10:]
    month = int(ten[2:4])
    day = int(ten[4:6])
    if not 1 <= month <= 12:
        return False
    if not (1 <= day <= 31 or 61 <= day <= 91):
        return False
    return _luhn(ten)


def _validate_card(value, m, whole):
    digits = "".join(c for c in value if c.isdigit())
    return 13 <= len(digits) <= 19 and _luhn(digits)


def _validate_otp(value, m, whole):
    if len(value) == 4 and 1900 <= int(value) <= 2099:
        return False
    start = max(0, m.start() - _OTP_BEFORE)
    end = min(len(whole), m.end() + _OTP_AFTER)
    return bool(_OTP_CONTEXT.search(whole[start:end]))


# (kind, compiled regex, capture group, validator)
_RULES = [
    ("private_key", r"-----BEGIN [A-Z0-9 ]*KEY-----[\s\S]*?-----END [A-Z0-9 ]*KEY-----", 0, None),
    ("api_key", r"sk-ant-[A-Za-z0-9_\-]{16,}", 0, None),
    ("api_key", r"(?<![A-Za-z0-9])(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}", 0, None),
    ("webhook_secret", r"(?<![A-Za-z0-9])whsec_[A-Za-z0-9+/=]{20,}", 0, None),
    ("api_key", r"(?<![A-Za-z0-9])lin_api_[A-Za-z0-9]{30,}", 0, None),
    ("api_key", r"(?<![A-Za-z0-9])hf_[A-Za-z0-9]{30,}", 0, None),
    ("api_key", r"(?<![A-Za-z0-9_\-])sk-(?:proj-|live-|test-)?[A-Za-z0-9_\-]{20,}", 0, None),
    ("github_token", r"(?<![A-Za-z0-9_])(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{22,})", 0, None),
    ("slack_token", r"(?<![A-Za-z0-9])xox[abposr]-[A-Za-z0-9\-]{10,}", 0, None),
    ("aws_key", r"(?<![A-Z0-9])(?:AKIA|ASIA)[0-9A-Z]{16}(?![A-Z0-9])", 0, None),
    ("google_api_key", r"(?<![A-Za-z0-9])AIza[0-9A-Za-z_\-]{35}", 0, None),
    ("gitlab_token", r"(?<![A-Za-z0-9])glpat-[A-Za-z0-9_\-]{20,}", 0, None),
    ("npm_token", r"(?<![A-Za-z0-9])npm_[A-Za-z0-9]{36,}", 0, None),
    ("jwt", r"(?<![A-Za-z0-9_\-])eyJ[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}", 0, None),
    ("bearer_token", r"\bBearer\s+([A-Za-z0-9\-._~+/]{16,}=*)", 1, None),
    ("url_credentials", r"\b[a-z][a-z0-9+.\-]*://([^\s:/@\[\]]+:[^\s/@\[\]]+)@", 1, None),
    ("url_param",
     r"[?&#;](?:token|key|api_key|apikey|sig|signature|code|access_token|refresh_token|id_token|password|pwd|passwd|secret|client_secret|auth)=([^&#\s\"'<>]+)",
     1, None),
    ("secret",
     r"(?<![\p{L}\p{N}])(?:password|passwd|pwd|lösenord|losenord|secret|token|api[_\-]?key|apikey|access[_\-]?key|client[_\-]?secret|private[_\-]?key|auth)(?:[_\-][A-Za-z0-9_]*)?(?![\p{L}\p{N}])[\"']?\s*[:=]\s*[\"']?([^\s\"',;\[\]\{\}]+)",
     1, None),
    ("personnummer", r"(?<![0-9\-])((?:19|20)?[0-9]{6}[\-+]?[0-9]{4})(?![0-9])", 1,
     lambda v, m, w: is_personnummer(v)),
    ("card_number", r"(?<![0-9:/=_.#\p{L}])[2-6](?:[ \-]?[0-9]){12,18}(?![0-9\p{L}])", 0, _validate_card),
    ("otp", r"(?<![0-9\p{L}])(?<![0-9][\-:/.,])[0-9]{4,8}(?![0-9\p{L}])(?![\-:/.,][0-9])", 0, _validate_otp),
]
_COMPILED = [(kind, regex.compile(pat, regex.IGNORECASE) if kind in ("bearer_token", "url_credentials", "url_param", "secret")
             else regex.compile(pat), grp, val) for kind, pat, grp, val in _RULES]


# ----------------------------------------------------------------- Layer 5

_ENTROPY_CANDIDATE = regex.compile(r"[^\s:=&?,;]{24,}")
_URL_IN_TEXT = regex.compile(r"(?:\b[a-z][a-z0-9+.\-]*://|\bwww\.)[^\s\"'<>]+", regex.IGNORECASE)
_SCHEME_PREFIX = regex.compile(r"^[A-Za-z][A-Za-z0-9+.\-]*://")
_BARE_DOMAIN = regex.compile(r"^(?:www\.)?[a-z0-9\-]+(?:\.[a-z0-9\-]+)*\.[a-z]{2,}(?:[/?#].*)?$")
_EMAIL = regex.compile(r"^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$")
_HEX_ONLY = regex.compile(r"^[0-9a-fA-F]{7,128}$")
_UUID = regex.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
_PREFIXED_ID = regex.compile(r"^[a-z]{2,10}(?:_[a-z]{2,8})?_[A-Za-z0-9]{8,}$")
_TRIM = "\"'`()<>[]{},;.:!?"
ENTROPY_THRESHOLD = 4.0


def shannon_entropy(s: str) -> float:
    if not s:
        return 0.0
    counts = Counter(s)
    n = len(s)
    return -sum((v / n) * math.log2(v / n) for v in counts.values())


def _class(c: str) -> int:
    if c.isupper():
        return 0
    if c.islower():
        return 1
    if c.isdigit():
        return 2
    return 3


def _class_switch_ratio(s: str) -> float:
    if len(s) < 2:
        return 0.0
    switches = sum(_class(a) != _class(b) for a, b in zip(s, s[1:]))
    return switches / (len(s) - 1)


def looks_like_high_entropy_secret(token: str) -> bool:
    if len(token) < 24 or MARKER in token:
        return False
    if _SCHEME_PREFIX.search(token) or _BARE_DOMAIN.search(token) or _EMAIL.search(token):
        return False
    if token.startswith(("/", "~/", "./", "../")):
        return False
    if _HEX_ONLY.search(token) or _UUID.search(token) or _PREFIXED_ID.search(token):
        return False
    letters = sum(c.isalpha() for c in token)
    digits = sum(c.isdigit() for c in token)
    if letters == 0 or digits == 0:
        return False
    if shannon_entropy(token) <= ENTROPY_THRESHOLD:
        return False
    return _class_switch_ratio(token) >= 0.35 or digits / len(token) >= 0.2


# ----------------------------------------------------------------- main

def redact(text: str) -> RedactionOutput:
    if not text:
        return RedactionOutput(text or "", 0, [])
    kinds: list[str] = []

    for kind, rx, grp, val in _COMPILED:
        matches = list(rx.finditer(text))
        if not matches:
            continue
        out = text
        for m in reversed(matches):
            s, e = m.span(grp)
            if s < 0 or e <= s:
                continue
            value = text[s:e]
            if value.startswith(MARKER):
                continue
            if val is not None and not val(value, m, text):
                continue
            out = out[:s] + MARKER + kind + "]" + out[e:]
            kinds.append(kind)
        text = out

    found = list(_ENTROPY_CANDIDATE.finditer(text))
    if found:
        urls = [u.span() for u in _URL_IN_TEXT.finditer(text)]
        out = text
        for m in reversed(found):
            if any(a < m.end() and m.start() < b for a, b in urls):
                continue
            raw = m.group()
            if MARKER in raw:
                continue
            lo, hi = 0, len(raw)
            while lo < hi and raw[lo] in _TRIM:
                lo += 1
            while hi > lo and raw[hi - 1] in _TRIM:
                hi -= 1
            if hi - lo < 24:
                continue
            token = raw[lo:hi]
            if looks_like_high_entropy_secret(token):
                out = out[:m.start() + lo] + MARKER + "high_entropy]" + out[m.start() + hi:]
                kinds.append("high_entropy")
        text = out

    return RedactionOutput(text, len(kinds), kinds)
