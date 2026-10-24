# Squidpal — macOS

Menu-bar app for macOS 14+ that logs your workday to a local folder, one JSONL
file per day. Reads window content through the **Accessibility API**
(`AXUIElement`). No network requests.

This is the macOS implementation. For what it captures, the file format and the
privacy picture, see the [top-level docs](../README.md).

## Build & run

Requires Xcode or the Command Line Tools (Swift 5.9+).

```bash
./build.sh                 # builds build/Squidpal.app (ad-hoc signed)
open build/Squidpal.app
```

Redaction self-test (same cases as Windows and Linux):

```bash
./build.sh test            # builds and runs all cases; works with just Command Line Tools
swift test                 # same cases via XCTest; requires Xcode
```

Package for a tester:

```bash
./build.sh dist            # universal app (Apple Silicon + Intel) in build/Squidpal-<version>.dmg
```

Without a Developer ID the app is ad-hoc signed and the tester must approve it
once (see `READ-ME-FIRST.txt`, bundled in the DMG). With a Developer ID account,
set `DEVELOPER_ID="Developer ID Application: Name (TEAMID)"` and
`NOTARY_PROFILE=<profile>` (created once with `xcrun notarytool store-credentials`);
the app is then signed with a hardened runtime, the DMG is notarized, and the
Accessibility permission survives across versions.

`build.sh` invokes `swiftc` directly instead of SwiftPM so it can pick an SDK
that matches the compiler on partially-updated Command Line Tools installs.

## Permissions

| Permission | Why | Where |
|------------|-----|-------|
| Accessibility | Read window text, focused field, selection, scroll | System Settings → Privacy & Security → Accessibility |
| Automation (per browser) | Fallback for reading the URL via AppleScript when AX doesn't provide it | Prompted automatically the first time |

The app asks for Accessibility on first launch and shows a ⚠︎ in the menu bar
until it's granted.

**After every rebuild** the ad-hoc-signed app's hash changes and macOS stops
trusting it, even if the checkbox still looks ticked. Remove the app from the
Accessibility list with the minus button and add it again.

## Where files go

The folder you choose on first launch (changeable from the menu). The choice is
saved as a security-scoped bookmark and survives restarts. Nothing is recorded
until a folder is chosen.

See [docs/FILE_FORMAT.md](../docs/FILE_FORMAT.md) for the schema.

## Known limitations

- **Firefox:** the URL is only read if Firefox exposes it via accessibility;
  there is no AppleScript fallback.
- Apps that draw their own text (games, some Java/Qt/canvas apps, Figma, the
  Google Docs/Sheets canvas) expose little or no text.
- Very large pages: the read stops after 3 s or 60,000 nodes per snapshot.
- `AXEnhancedUserInterface` is set on Chromium browsers; this can make window
  animations and some window managers (Rectangle, Magnet) slower.
- Editing a line writes the whole new version of the line, not just the change.

## Troubleshooting

**`this SDK is not supported by the compiler`** — Command Line Tools are
half-updated (e.g. Swift 5.10 next to MacOSX15.sdk). `build.sh` tries a MacOSX14
SDK automatically; if that fails, reinstall:

```bash
sudo rm -rf /Library/Developer/CommandLineTools
xcode-select --install
```

Or install Xcode from the App Store and run
`sudo xcode-select -s /Applications/Xcode.app`; `swift test` then works too.

`warning: could not determine XCTest paths` is harmless — the Command Line Tools
lack XCTest, which is why `./build.sh test` exists.

> Note: the app is **Squidpal.app**, bundle id **io.squidler.squidpal**. The
> Swift module/target is still named `DayLog` internally (a code symbol only).
