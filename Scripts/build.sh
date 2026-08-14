#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="KeelBar"
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
cp "$ROOT/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Ad-hoc sign so macOS launches it reliably
codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1 || true

echo "✓ Done: $APP_BUNDLE"
echo "  Run: open \"$APP_BUNDLE\""

if [[ "$CONFIG" == "release" ]]; then
  STAGE="$ROOT/dist/.dmg-stage"
  DMG="$ROOT/dist/${APP_NAME}.dmg"
  echo "→ Packaging ${DMG}"
  rm -rf "$STAGE"
  mkdir -p "$STAGE"
  ditto "$APP_BUNDLE" "$STAGE/${APP_NAME}.app"
  ln -s /Applications "$STAGE/Applications"
  rm -f "$DMG"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  rm -rf "$STAGE"
  echo "✓ DMG: $DMG"
fi
