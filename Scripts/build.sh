#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="TaskListBar"
BUILD_DIR="$ROOT/.build"
APP_BUNDLE="$ROOT/dist/${APP_NAME}.app"
CONFIG="${1:-debug}"

echo "→ Building ${APP_NAME} (${CONFIG})…"
swift build -c "$CONFIG"

BIN="$BUILD_DIR/$CONFIG/$APP_NAME"
if [[ ! -x "$BIN" ]]; then
  echo "Binary not found: $BIN" >&2
  exit 1
fi

echo "→ Assembling ${APP_BUNDLE}"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BIN" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Ad-hoc sign so macOS launches it reliably
codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1 || true

echo "✓ Done: $APP_BUNDLE"
echo "  Run: open \"$APP_BUNDLE\""
