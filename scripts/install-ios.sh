#!/usr/bin/env bash
# Build, sign, install, and launch the iOS companion on a paired device.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -ne 1 ]]; then
  echo "Usage: $0 DEVICE_UDID" >&2
  echo "Find your phone with: xcrun devicectl list devices" >&2
  exit 2
fi
REEL_DEVICE_ID="$1"
REEL_DERIVED_DATA="build/iOS-Device"
if [[ -z "${TEAM:-}" ]]; then
  echo "Set TEAM to your Apple Developer team ID." >&2
  echo "Usage: TEAM=YOUR_TEAM_ID $0 DEVICE_UDID" >&2
  exit 2
fi
REEL_SIGNING_ARGS=("DEVELOPMENT_TEAM=$TEAM")
if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate
fi
xcodebuild -project Reel.xcodeproj -scheme ReelMobile -configuration Release \
  -destination "platform=iOS,id=$REEL_DEVICE_ID" \
  -derivedDataPath "$REEL_DERIVED_DATA" -allowProvisioningUpdates \
  "${REEL_SIGNING_ARGS[@]}" build
xcrun devicectl device install app --device "$REEL_DEVICE_ID" \
  "$REEL_DERIVED_DATA/Build/Products/Release-iphoneos/ReelMobile.app"
xcrun devicectl device process launch --device "$REEL_DEVICE_ID" com.gamojo.reel.mobile
