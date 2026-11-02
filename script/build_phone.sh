#!/usr/bin/env bash
set -euo pipefail

# Build-only. Never installs, launches, starts a listener, or names a real device.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:---simulator}"
case "$MODE" in
  --simulator) DESTINATION='generic/platform=iOS Simulator'; PRODUCT='Debug-iphonesimulator' ;;
  --device) DESTINATION='generic/platform=iOS'; PRODUCT='Debug-iphoneos' ;;
  *) echo 'usage: script/build_phone.sh [--simulator|--device]' >&2; exit 2 ;;
esac
STAGING_ROOT='/private/tmp/OpenCore-phone-source'
DERIVED_ROOT='/private/tmp/opencore-phone-dd'
if [[ -L "$STAGING_ROOT" || -L "$DERIVED_ROOT" ]]; then
  echo 'Build directories must not be symlinks' >&2; exit 1
fi
mkdir /private/tmp/opencore-xcodebuild.lock 2>/dev/null || { echo 'Another OpenCore Xcode build is active' >&2; exit 75; }
trap 'rmdir /private/tmp/opencore-xcodebuild.lock' EXIT
if pgrep -x xcodebuild >/dev/null; then echo 'Wait for the active xcodebuild to finish' >&2; exit 75; fi
mkdir -p "$STAGING_ROOT/Apps/OpenCorePhone"
cp "$ROOT_DIR/Package.swift" "$STAGING_ROOT/Package.swift"
rsync -a --delete "$ROOT_DIR/Sources/" "$STAGING_ROOT/Sources/"
rsync -a --delete "$ROOT_DIR/Tests/" "$STAGING_ROOT/Tests/"
rsync -a --delete --exclude '*.xcodeproj' --exclude '*.xcworkspace' --exclude Generated \
  "$ROOT_DIR/Apps/OpenCorePhone/" "$STAGING_ROOT/Apps/OpenCorePhone/"
(cd "$STAGING_ROOT/Apps/OpenCorePhone" && /opt/homebrew/bin/xcodegen generate)
if [[ "$MODE" == --simulator ]]; then
  xcodebuild -project "$STAGING_ROOT/Apps/OpenCorePhone/OpenCorePhone.xcodeproj" \
    -scheme OpenCorePhone -configuration Debug -derivedDataPath "$DERIVED_ROOT" \
    -destination "$DESTINATION" CODE_SIGNING_ALLOWED=NO build
else
  xcodebuild -project "$STAGING_ROOT/Apps/OpenCorePhone/OpenCorePhone.xcodeproj" \
    -scheme OpenCorePhone -configuration Debug -derivedDataPath "$DERIVED_ROOT" \
    -destination "$DESTINATION" build
fi
echo "Built: $DERIVED_ROOT/Build/Products/$PRODUCT/OpenCorePhone.app"
