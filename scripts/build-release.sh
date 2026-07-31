#!/usr/bin/env bash
#
# Build a distributable Release build of Reel and zip it up.
#
# The result runs on any compatible Mac WITHOUT Xcode. Because it is not
# notarized through Apple's paid Developer Program, the first launch needs a
# one-time "Open Anyway" in System Settings → Privacy & Security (see README).
# To remove that step entirely you'd need a $99/year Apple Developer Program
# membership and a notarization step (notarytool + stapler) added below.
#
# Usage:  ./scripts/build-release.sh
# Output: dist/Reel.zip   ← upload this to a GitHub Release.

set -euo pipefail
cd "$(dirname "$0")/.."

APP_PATH="build/Build/Products/Release/Reel.app"

# Regenerate the Xcode project from project.yml if XcodeGen is installed
# (the project is also committed, so this is optional).
if command -v xcodegen >/dev/null 2>&1; then
  echo "▶︎ Regenerating Xcode project…"
  xcodegen generate
fi

echo "▶︎ Building Release…"
xcodebuild -project Reel.xcodeproj -scheme Reel -configuration Release \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  build

# Prefer an available Apple Development certificate because macOS privacy
# permissions persist its designated requirement across rebuilds. Callers can
# select a different identity with REEL_SIGNING_IDENTITY. Machines without a
# certificate still get an ad-hoc build with a stable local requirement.
REEL_LOCAL_SIGNING_IDENTITY="${REEL_SIGNING_IDENTITY:-}"
if [[ -z "$REEL_LOCAL_SIGNING_IDENTITY" ]] && command -v security >/dev/null 2>&1; then
  REEL_LOCAL_SIGNING_IDENTITY="$(
    security find-identity -v -p codesigning |
      awk '/"Apple Development:/{print $2; exit}'
  )"
fi

if [[ -n "$REEL_LOCAL_SIGNING_IDENTITY" ]]; then
  echo "▶︎ Signing with Apple Development identity…"
  codesign --force --deep --sign "$REEL_LOCAL_SIGNING_IDENTITY" \
    --options runtime \
    --preserve-metadata=entitlements \
    "$APP_PATH"
else
  STABLE_REQUIREMENT='=designated => identifier "com.gamojo.reel"'
  echo "▶︎ Applying stable ad-hoc signing requirement…"
  codesign --force --deep --sign - --options runtime \
    --requirements "$STABLE_REQUIREMENT" \
    --preserve-metadata=entitlements \
    "$APP_PATH"
fi
codesign --verify --deep --strict "$APP_PATH"

echo "▶︎ Packaging…"
mkdir -p dist
rm -f dist/Reel.zip
ditto -c -k --keepParent "$APP_PATH" dist/Reel.zip

echo "✓ Done → dist/Reel.zip ($(du -h dist/Reel.zip | cut -f1))"
