#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="KeelBar"
BUILD_DIR="$ROOT/.build"
APP_BUNDLE="$ROOT/dist/${APP_NAME}.app"
CONFIG="${1:-debug}"

echo "→ Building ${APP_NAME} (${CONFIG})…"
# Native arm64 on Apple Silicon; release uses SPM -O + WMO by default.
SWIFT_BUILD_ARGS=(-c "$CONFIG" --arch arm64)
if [[ "$CONFIG" == "release" ]]; then
  # Drop debug info from the linked product; strip finishes the job.
  SWIFT_BUILD_ARGS+=(-Xswiftc -gnone)
fi
swift build "${SWIFT_BUILD_ARGS[@]}"

BIN="$BUILD_DIR/$CONFIG/$APP_NAME"
if [[ ! -x "$BIN" ]]; then
  echo "Binary not found: $BIN" >&2
  exit 1
fi

if [[ "$CONFIG" == "release" ]]; then
  echo "→ Stripping ${BIN}"
  strip -x "$BIN" >/dev/null 2>&1 || true
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

install_to_applications() {
  local dest_dir="/Applications"
  if [[ ! -w "$dest_dir" ]]; then
    dest_dir="${HOME}/Applications"
    mkdir -p "$dest_dir"
  fi
  local dest="${dest_dir}/${APP_NAME}.app"
  echo "→ Installing ${dest}"
  if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    pkill -x "$APP_NAME" || true
    sleep 0.4
  fi
  rm -rf "$dest"
  ditto "$APP_BUNDLE" "$dest"
  codesign --force --deep --sign - "$dest" >/dev/null 2>&1 || true
  echo "✓ Installed: $dest"
  echo "  Run: open \"$dest\""
}

if [[ "$CONFIG" == "release" ]]; then
  install_to_applications

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
else
  echo "  Run: open \"$APP_BUNDLE\""
fi
