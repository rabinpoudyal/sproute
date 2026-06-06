#!/usr/bin/env bash
# Build, assemble, and code-sign Sprout.app (app + root helper + LaunchDaemon).
# Requires `make certs` to have run first (signing identity in the keychain and
# the matching leaf hash in SigningConstants.swift).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build/release"
APP="$ROOT/build/Sprout.app"
IDENTITY="${SPROUT_SIGN_IDENTITY:-Sprout Dev}"

echo "==> swift build -c release"
swift build -c release --package-path "$ROOT"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Library/LaunchDaemons"

cp "$BUILD/SproutApp"     "$APP/Contents/MacOS/SproutApp"
cp "$BUILD/sprout-helper" "$APP/Contents/MacOS/com.sprout.helper"
cp "$ROOT/packaging/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/packaging/com.sprout.helper.plist" \
    "$APP/Contents/Library/LaunchDaemons/com.sprout.helper.plist"

echo "==> signing inside-out with identity: $IDENTITY"
# Helper first (innermost), then the app binary, then the outer bundle. Both
# binaries take their designated identifier explicitly so the pinned
# `identifier "..."` requirements match.
codesign --force --options runtime \
    -i com.sprout.helper -s "$IDENTITY" \
    "$APP/Contents/MacOS/com.sprout.helper"
codesign --force --options runtime \
    -i com.sprout.app -s "$IDENTITY" \
    "$APP/Contents/MacOS/SproutApp"
codesign --force --options runtime \
    -i com.sprout.app -s "$IDENTITY" \
    "$APP"

echo "==> verifying signatures"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> designated requirements (sanity):"
codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p'
codesign -d -r- "$APP/Contents/MacOS/com.sprout.helper" 2>&1 \
    | sed -n 's/^designated => //p'

echo "==> built: $APP"
