#!/bin/bash
# Builds DayLog with swiftc directly (SwiftPM ignores SDKROOT when compiling
# Package.swift, which breaks on mismatched Command Line Tools).
#
#   ./build.sh          build build/Squidpal.app for this Mac's architecture
#   ./build.sh test     build and run the redactor self-test
#   ./build.sh dist     universal app (Apple Silicon + Intel) in build/DayLog.dmg
#
# Signing for dist:
#   default                       ad hoc (tester must allow it once, see READ-ME-FIRST.txt)
#   DEVELOPER_ID="Developer ID Application: Name (TEAMID)"
#                                 Developer ID + hardened runtime
#   NOTARY_PROFILE=<profile>      also notarize + staple (profile created once with
#                                 `xcrun notarytool store-credentials <profile>`)
set -euo pipefail

# The redactor self-test reads the SAME shared fixtures as Windows/Linux, so it
# cannot silently drift. Resolve them to an absolute path for the test runner.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export SQUIDPAL_FIXTURES="$(cd "$SCRIPT_DIR/.." && pwd)/shared/redaction-fixtures.json"
cd "$(dirname "$0")"

MODE="${1:-app}"
SWIFTC="$(xcrun --find swiftc 2>/dev/null || command -v swiftc)"
MIN_OS="14.0"

# Pick an SDK that matches the compiler.
if [ -z "${SDKROOT:-}" ]; then
  SWIFT_MAJOR="$("$SWIFTC" --version 2>&1 | sed -n 's/.*Swift version \([0-9]*\)\..*/\1/p' | head -1)"
  SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
  if [ "$SWIFT_MAJOR" = "5" ] && [[ "$(basename "$SDKROOT")" =~ ^MacOSX(1[5-9]|2[0-9]) ]]; then
    ALT="$(ls -d "$(dirname "$SDKROOT")"/MacOSX14*.sdk 2>/dev/null | sort -V | tail -1 || true)"
    if [ -z "$ALT" ]; then
      echo "ERROR: Swift 5 does not match $(basename "$SDKROOT") and no MacOSX14 SDK is present. See README -> Troubleshooting."
      exit 1
    fi
    echo "Swift 5 + $(basename "$SDKROOT") mismatch - using $(basename "$ALT")"
    SDKROOT="$ALT"
  fi
fi
export SDKROOT
echo "swiftc: $SWIFTC"
echo "SDK:    $SDKROOT"

# build_arch <arch> [test]  → build/obj/<arch>/DayLog (or redactor-selftest)
build_arch() {
  local arch="$1" what="${2:-app}"
  local obj="build/obj/$arch"
  mkdir -p "$obj"
  local common=(-sdk "$SDKROOT" -target "$arch-apple-macos$MIN_OS" -swift-version 5 -I "$obj" -L "$obj")
  lib() {
    local name="$1"; shift
    "$SWIFTC" "${common[@]}" -O -parse-as-library -module-name "$name" \
      -emit-library -static -o "$obj/lib$name.a" \
      -emit-module -emit-module-path "$obj/$name.swiftmodule" "$@"
  }
  echo "→ [$arch] RedactorCore"
  lib RedactorCore Sources/RedactorCore/*.swift
  if [ "$what" = "test" ]; then
    echo "→ [$arch] RedactorFixtures"
    lib RedactorFixtures Sources/RedactorFixtures/*.swift
    echo "→ [$arch] redactor-selftest"
    "$SWIFTC" "${common[@]}" -O -module-name RedactorSelftest -lRedactorCore -lRedactorFixtures \
      Sources/redactor-selftest/main.swift -o "$obj/redactor-selftest"
  else
    echo "→ [$arch] DayLog"
    "$SWIFTC" "${common[@]}" -O -parse-as-library -module-name DayLog \
      -lRedactorCore Sources/DayLog/*.swift -o "$obj/DayLog"
  fi
}

assemble_app() {  # assemble_app <binary>
  local APP="build/Squidpal.app"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS"
  cp "$1" "$APP/Contents/MacOS/Squidpal"
  cp Support/Info.plist "$APP/Contents/Info.plist"
  mkdir -p "$APP/Contents/Resources"
  cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  cp Support/menubar/*.png "$APP/Contents/Resources/"
  touch "$APP"   # make Finder pick up the new icon
}

sign_app() {
  local APP="build/Squidpal.app"
  if [ -n "${DEVELOPER_ID:-}" ]; then
    echo "→ Signerar med $DEVELOPER_ID"
    codesign --force --options runtime --timestamp \
      --entitlements Support/DayLog.entitlements \
      --sign "$DEVELOPER_ID" --identifier io.squidler.squidpal "$APP"
  else
    codesign --force --sign - --identifier io.squidler.squidpal "$APP"
  fi
  codesign --verify --strict "$APP"
}

NATIVE="$(uname -m)"

case "$MODE" in
  test)
    build_arch "$NATIVE" test
    echo
    "./build/obj/$NATIVE/redactor-selftest"
    ;;

  app)
    build_arch "$NATIVE"
    assemble_app "build/obj/$NATIVE/DayLog"
    sign_app
    echo
    echo "Done: $PWD/build/Squidpal.app"
    echo "Run: open build/Squidpal.app   (quit a running Squidpal first)"
    ;;

  dist)
    build_arch arm64
    build_arch x86_64
    mkdir -p build/obj/universal
    lipo -create build/obj/arm64/DayLog build/obj/x86_64/DayLog -output build/obj/universal/DayLog
    lipo -info build/obj/universal/DayLog
    assemble_app build/obj/universal/DayLog
    sign_app

    VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Support/Info.plist)"
    STAGE="build/dmg"
    DMG="build/Squidpal-$VERSION.dmg"
    rm -rf "$STAGE" "$DMG"
    mkdir -p "$STAGE"
    cp -R build/Squidpal.app "$STAGE/"
    ln -s /Applications "$STAGE/Program"
    cp READ-ME-FIRST.txt "$STAGE/READ-ME-FIRST.txt"
    hdiutil create -volname "Squidpal $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

    if [ -n "${DEVELOPER_ID:-}" ]; then
      codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"
      if [ -n "${NOTARY_PROFILE:-}" ]; then
        echo "-> Notarizing (takes a few minutes)"
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
      fi
    fi
    echo
    echo "Done: $PWD/$DMG"
    if [ -z "${DEVELOPER_ID:-}" ]; then
      echo "Ad-hoc signed: the tester must approve the app once (see 'READ-ME-FIRST.txt' in the DMG)."
    fi
    ;;

  *)
    echo "Unknown mode: $MODE (use: test, dist, or nothing)"; exit 1 ;;
esac
