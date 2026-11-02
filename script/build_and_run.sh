#!/usr/bin/env bash
set -euo pipefail

# Keep build inputs and products outside the iCloud-synced checkout.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-run}"
STAGING_ROOT="/private/tmp/OpenCore-review-source"
DERIVED_ROOT="/private/tmp/opencore-review-dd"
SCHEME="${2:-OpenCore}"
APP_BUNDLE="$DERIVED_ROOT/Build/Products/Debug/$SCHEME.app"
case "$MODE" in
  run|--verify|--debug|--logs|--telemetry|--build-only) ;;
  *) echo "usage: $0 [--build-only|--verify|--debug|--logs|--telemetry] [OpenCore|OpenCoreReview]" >&2; exit 2 ;;
esac

case "$SCHEME" in
  OpenCore) ;;
  OpenCoreReview)
    if [[ "$MODE" != --build-only ]]; then echo "Review builds are build-only; never install as production" >&2; exit 2; fi
    ;;
  *) echo "Unknown app scheme" >&2; exit 2 ;;
esac

# Refuse a redirected staging directory before rsync's bounded cleanup.
if [[ -L "$STAGING_ROOT" || -L "$DERIVED_ROOT" ]]; then
  echo "Build directories must not be symlinks" >&2; exit 1
fi
mkdir /private/tmp/opencore-xcodebuild.lock 2>/dev/null || { echo "Another OpenCore Xcode build is active" >&2; exit 75; }
trap 'rmdir /private/tmp/opencore-xcodebuild.lock' EXIT
if pgrep -x xcodebuild >/dev/null; then echo "Wait for the active xcodebuild to finish" >&2; exit 75; fi
mkdir "$STAGING_ROOT.lock" 2>/dev/null || { echo "Another OpenCore app build is active" >&2; exit 75; }
trap 'rmdir "$STAGING_ROOT.lock"; rmdir /private/tmp/opencore-xcodebuild.lock' EXIT
mkdir -p "$STAGING_ROOT/Sources" "$STAGING_ROOT/Tests" "$STAGING_ROOT/Apps/OpenCoreMac"
cp "$ROOT_DIR/Package.swift" "$STAGING_ROOT/Package.swift"
rsync -a --delete "$ROOT_DIR/Sources/" "$STAGING_ROOT/Sources/"
rsync -a --delete "$ROOT_DIR/Tests/" "$STAGING_ROOT/Tests/"
rsync -a --delete --exclude '*.xcodeproj' --exclude '*.xcworkspace' --exclude Generated \
  "$ROOT_DIR/Apps/OpenCoreMac/" "$STAGING_ROOT/Apps/OpenCoreMac/"
(cd "$STAGING_ROOT/Apps/OpenCoreMac" && /opt/homebrew/bin/xcodegen generate)
xcodebuild -project "$STAGING_ROOT/Apps/OpenCoreMac/OpenCore.xcodeproj" \
  -scheme "$SCHEME" -configuration Debug -derivedDataPath "$DERIVED_ROOT" \
  -destination 'platform=macOS,arch=arm64' build
codesign --verify --deep --strict "$APP_BUNDLE"
if [[ "$MODE" == --build-only ]]; then exit 0; fi

# Preserve the previous installed app before replacing it. No user data is moved.
pkill -x OpenCore >/dev/null 2>&1 || true
# A terminating process can still be registered with Launch Services. Replacing and opening
# immediately produced -600 during the audit; wait for exit before touching its bundle.
for _ in {1..50}; do
  if ! pgrep -x OpenCore >/dev/null; then break; fi
  sleep 0.1
done
if pgrep -x OpenCore >/dev/null; then
  echo "OpenCore has not exited; installed app was left in place" >&2
  exit 1
fi
BACKUP_ROOT="/private/tmp/OpenCore-app-backups/$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$BACKUP_ROOT"
INSTALL_STAGE="/Applications/.OpenCore-review-$$.app"
ditto "$APP_BUNDLE" "$INSTALL_STAGE"
if [[ -d /Applications/OpenCore.app ]]; then
  mv /Applications/OpenCore.app "$BACKUP_ROOT/OpenCore.app"
fi
if ! mv "$INSTALL_STAGE" /Applications/OpenCore.app; then
  if [[ -d "$BACKUP_ROOT/OpenCore.app" ]]; then mv "$BACKUP_ROOT/OpenCore.app" /Applications/OpenCore.app; fi
  exit 1
fi
case "$MODE" in
  --debug) lldb -- /Applications/OpenCore.app/Contents/MacOS/OpenCore ;;
  --logs|--telemetry)
    open /Applications/OpenCore.app
    /usr/bin/log stream --info --style compact --predicate 'process == "OpenCore"'
    ;;
  --verify)
    # Launch Services can briefly lag process exit. Retry the same installed bundle, bounded.
    LAUNCHED=false
    for _ in 1 2 3; do
      if open /Applications/OpenCore.app; then LAUNCHED=true; break; fi
      sleep 1
    done
    if [[ "$LAUNCHED" != true ]]; then echo "OpenCore could not be launched" >&2; exit 1; fi
    for _ in 1 2 3 4 5; do
      if pgrep -x OpenCore >/dev/null; then echo "OpenCore launched; previous bundle: $BACKUP_ROOT/OpenCore.app"; exit 0; fi
      sleep 1
    done
    echo "OpenCore did not stay running" >&2; exit 1
    ;;
  *) open /Applications/OpenCore.app ;;
esac
