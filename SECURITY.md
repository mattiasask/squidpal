# Security Policy

Squidpal reads sensitive on-screen content and writes it to disk, so security
reports are taken seriously — especially the case where a secret is written to a
log file that should have been masked.

## Reporting a vulnerability

**Please do not open a public issue for a security problem, and never paste a
real secret into an issue or PR.**

Report privately through GitHub's **[Private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)**
(the **Security** tab → **Report a vulnerability** on this repository). That
keeps the report and any discussion private until a fix is ready.

When you report, please include:

- Platform and version (e.g. macOS 14.5, Windows 11 23H2, Ubuntu 24.04 GNOME/Wayland).
- What happened, and a **redacted** reproduction — describe the *shape* of the
  secret that leaked (e.g. "a 40-char hex token in a `key=` query parameter"),
  not the secret itself.

## What counts as a security issue

- A secret format that Squidpal writes to the log unmasked (a missed redaction).
- A way to make Squidpal read a password field or a password manager.
- Anything that causes Squidpal to send data off the machine (it never should).

## What is out of scope

- The inherent fact that Squidpal records screen activity — that is the tool's
  purpose, not a vulnerability. See [docs/PRIVACY.md](docs/PRIVACY.md).
- Over-masking (Squidpal redacting something harmless). That's a normal bug, not
  a security issue — file it via the regular issue template.
- Secrets exposed because log files were put in a synced/shared folder by the
  user. Choosing where the files live is the user's decision.

## A note on redaction

Redaction is **best-effort and pattern-based**. It is a safety net, not a
guarantee, and the project documents this plainly. A missed pattern is a bug
worth fixing, and we want to hear about it — but please treat all log files as
sensitive regardless.
