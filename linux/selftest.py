#!/usr/bin/env python3
"""Runs the shared fixtures against the Python redactor. Same cases as macOS/Windows.
    python3 selftest.py [path-to-fixtures.json]
"""
import json, sys, os
sys.path.insert(0, os.path.dirname(__file__))
from daylog.redactor import redact, is_sensitive_field_name, is_blocked_app, _luhn, MARKER

path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "shared", "redaction-fixtures.json")
doc = json.load(open(path, encoding="utf-8"))
passed = failed = 0

def report(name, problem):
    global passed, failed
    if problem is None:
        passed += 1; print(f"ok    {name}")
    else:
        failed += 1; print(f"FAIL  {name}: {problem}")

for c in doc["redaction"]:
    out = redact(c["input"])
    probs = []
    if c["kind"]:
        if f"{MARKER}{c['kind']}]" not in out.text: probs.append(f"expected {c['kind']}")
    elif out.count: probs.append(f"unexpected {out.kinds}")
    probs += [f'still has "{g}"' for g in c["gone"] if g in out.text]
    probs += [f'lost "{k}"' for k in c["kept"] if k not in out.text]
    again = redact(out.text)
    if again.count: probs.append(f"2nd pass {again.kinds}")
    report(c["name"], "; ".join(probs) + " -> " + out.text if probs else None)

for c in doc["sensitive_field_names"]:
    got = is_sensitive_field_name(c["input"])
    report(f"field: {c['input']}", None if got == c["expected"] else f"expected {c['expected']}, got {got}")

report("luhn ok", None if _luhn("4111111111111111") else "expected true")
report("luhn bad", None if not _luhn("4111111111111112") else "expected false")
report("blocked 1Password", None if is_blocked_app("1password", "1Password") else "expected true")
report("blocked Chrome", None if not is_blocked_app("google-chrome", "Google Chrome") else "expected false")

print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
