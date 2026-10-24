# Contributing to Squidpal

Thanks for your interest. Squidpal is an early prototype, so the most useful
contributions right now are bug reports from real desktops, redaction
improvements, and platform fixes.

## Ground rules

- **Be honest about limits.** This is a tool that records sensitive activity.
  Don't claim guarantees the code can't keep. If a change narrows or widens what
  gets masked, say so in the PR.
- **Never commit a real secret.** Not in code, not in a test fixture, not in an
  issue. Fixtures use clearly fake values assembled at runtime.
- **No telemetry, ever.** Squidpal makes no network requests. A PR that adds one
  will be declined.

## The one hard rule: redaction parity

The masking rules are implemented three times — Swift (`macos/`), C#
(`windows/`), Python (`linux/`) — and must stay identical. They are tested
against a single shared fixture set: [`shared/redaction-fixtures.json`](shared/redaction-fixtures.json).

If you change masking behavior:

1. Add or update a case in `shared/redaction-fixtures.json` (a `redaction` case
   with `gone`/`kept`, or a `sensitive_field_names` case).
2. Make the change in **all three** implementations
   (`Redactor.swift`, `Redactor.cs`, `redactor.py`).
3. Run all three self-tests and confirm they still pass (see below). CI runs the
   same three on every push.

A masking change that lands in one platform but not the others will fail CI and
won't be merged.

## Running the tests

```bash
# Linux / macOS (Python 3 + the `regex` package):
python3 linux/selftest.py

# .NET 8 (any OS):
dotnet run --project windows/src/DayLog.SelfTest -c Release -- shared/redaction-fixtures.json

# macOS with the Swift toolchain:
cd macos && ./build.sh test
```

Each platform's own README has full build instructions for the app itself.

## Style

- An `.editorconfig` is included; most editors pick it up.
- Match the surrounding code. Swift and C# use 4-space indent; Python follows
  PEP 8; keep comments focused on *why*, not *what*.
- Known gap: the app UI strings are currently Swedish. Internationalization PRs
  are welcome — keep user-facing strings together and translatable.

## Reporting bugs

Use the issue templates. For anything involving a secret that leaked into a log,
treat it as a security report instead — see [SECURITY.md](SECURITY.md).

By contributing, you agree your contributions are licensed under the project's
[MIT License](LICENSE).
