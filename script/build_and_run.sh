#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="AnyNotify"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/.build/DerivedData"
CONFIGURATION="Debug"

if [[ "$MODE" == "release" || "$MODE" == "--release" ]]; then
  CONFIGURATION="Release"
fi

APP_BUNDLE="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

if [[ "$CONFIGURATION" == "Debug" ]]; then
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi

xcodebuild \
  -project "$ROOT_DIR/AnyNotify.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  build

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  --release|release)
    printf 'Release build succeeded: %s\n' "$APP_BUNDLE"
    ;;
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.mengfs.AnyNotify"'
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|release|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
