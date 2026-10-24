# Redaction

Squidpal strips secrets **locally, before anything is written to disk**. Masked
values are replaced with `[REDACTED:<kind>]` (e.g. `[REDACTED:api_key]`). The
per-record `redactions` count and `redaction_kinds` object record *that*
something was masked and *what kind* — never the value.

The rules are implemented three times and kept identical:

- `macos/Sources/RedactorCore/Redactor.swift` (Swift)
- `windows/src/DayLog.Core/Redactor.cs` (C#)
- `linux/daylog/redactor.py` (Python)

All three are tested against one shared fixture set,
[`shared/redaction-fixtures.json`](../shared/redaction-fixtures.json), so the
behavior cannot drift between platforms.

## The layers

1. **Sensitive fields are never read.** The OS "password field" role
   (`AXSecureTextField` / UIA `IsPassword` / AT-SPI `password text`) is skipped
   entirely, as are fields whose label, placeholder, id or name looks like a
   secret (`password`, `pin`, `cvc`, `otp`, `säkerhetskod`, …).
2. **Concealed clipboards are never stored.** Clipboard entries that password
   managers mark as secret (macOS `org.nspasteboard.ConcealedType`, KDE
   `x-kde-passwordManagerHint`, …) are dropped.
3. **Password managers record only the app name.** 1Password, Bitwarden,
   Dashlane, KeePass, the system keychains, etc. — their window contents are
   never read.
4. **Pattern rules** mask, wherever they appear in text:
   - Known key formats: OpenAI `sk-…`/`sk-ant-…`, Stripe `sk_live_`/`rk_live_`/
     `whsec_`, GitHub `ghp_`/`github_pat_`, Slack `xox…`, AWS `AKIA…`, Google
     `AIza…`, GitLab `glpat-`, npm `npm_`, Linear, Hugging Face, Bearer tokens, JWTs.
   - PEM private-key blocks.
   - `key = value` where the key is `password`, `secret`, `token`, `api_key`, …
   - URLs with embedded credentials (`https://user:pass@…`) and secret query
     parameters (`token=`, `code=`, `access_token=`, …).
   - Card numbers that pass the Luhn check, and Swedish personal ID numbers
     (personnummer).
   - One-time codes: 4–8 digits near a word like `code`, `kod`, `passcode`,
     `OTP`, `BankID`.
5. **Entropy check** masks long, random-looking strings (≥24 chars, mixed
   classes, high Shannon entropy) — a catch-all for unknown token formats. It
   deliberately skips URLs, file paths, hashes, UUIDs and prefixed object ids
   (`cus_…`, `pi_…`, `cs_test_…`).

## Known limits

Redaction is **pattern-based and best-effort — not a guarantee.**

- A password typed into an *unlabeled* plain text field, with no `password:`
  marker near it, won't be caught.
- It errs toward over-masking: `password: ` followed by an ordinary word masks
  that word.
- Four-digit numbers in 1900–2099 are treated as years, not one-time codes.
- One-time-code detection needs a whole context word (`code`, `kod`, `passcode`,
  `BankID`, `OTP`) within ~30 characters before or ~12 after the digits — so a
  meeting ID next to the word "passcode" gets masked (intentional; better safe).

**Treat every log file as sensitive regardless of redaction.** If you find a
secret format that slips through, that's a bug worth reporting — see
[SECURITY.md](../SECURITY.md).

## Changing the rules

Any change must land in all three implementations and be covered by a case in
`shared/redaction-fixtures.json`. See [CONTRIBUTING.md](../CONTRIBUTING.md).
