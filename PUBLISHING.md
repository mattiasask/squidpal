# Publishing Squidpal to GitHub

This repo is assembled and ready to publish. It isn't a git repository yet (so
there's no history to scrub) and nothing has been pushed anywhere. Here's how to
put it up.

## 1. Create the repository

On GitHub, create a new **empty** repository (no README/license/.gitignore — this
repo already has them) **under your personal account**. Suggested name: `squidpal`.
Hosting it on your personal account is fine and independent of the license — the
code stays **© Squidler AB** (see `LICENSE`), wherever the repo lives. Decide now
whether it should be **public** or start **private** — you can flip private → public later.

## 2. Initialize and push

From this folder (`squidpal/`):

```bash
git init -b main
git add .
git commit -m "Initial public release of Squidpal"
git remote add origin https://github.com/mattiasask/squidpal.git   # or the SSH URL
git push -u origin main
```

If you use the GitHub CLI, steps 1–2 collapse to:

```bash
gh repo create mattiasask/squidpal --private --source=. --remote=origin --push
```

## 3. After the first push

- **Check the Actions tab.** CI runs three jobs: macOS (Swift build + tests),
  Windows (.NET build + tests), Linux (Python tests + import check). The macOS
  and Linux jobs have been verified locally; the **Windows job compiles the tray
  app (`DayLog.Win`) for the first time** — if it's red, the log will show the
  compile error, which is quick to fix. (The .NET *self-test* that gates
  redaction has been verified independently.)
- **Turn on private vulnerability reporting:** Settings → Code security →
  *Private vulnerability reporting* → Enable. `SECURITY.md` points people there.
- Add topics (`macos`, `windows`, `linux`, `accessibility`, `productivity`,
  `privacy`) and a short description. Hold the website field until yours is live.

## Before you flip it public

- [ ] You're comfortable with the privacy framing in `README.md` and
      `docs/PRIVACY.md` — this tool records other people's on-screen words, and
      the docs say so plainly on purpose.
- [ ] CI is green (or you know why Windows is red and are fixing it).
- [ ] No real secrets anywhere (the tree was scanned; fixtures use fake values).

## Internal code symbols (optional later cleanup)

Everything user-visible is **Squidpal**: the app/binary names, the macOS bundle
id `io.squidler.squidpal`, the Windows `Squidpal.exe` and `%APPDATA%\Squidpal`,
the Linux `squidpal` launcher and `~/.config/squidpal`, and all icons.

`daylog` remains only as an internal **code symbol** that users never see:

- macOS: the Swift module/target `DayLog` and `Sources/DayLog/`.
- Windows: the C# namespace `DayLog` and the `DayLog.Win` / `DayLog.Core` project folders.
- Linux: the Python package `daylog/` (imported as `daylog`).

Renaming these is pure cosmetics for people reading the source. It can be done
any time in one mechanical pass, with each platform's build in front of you.
