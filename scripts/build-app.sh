#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="MindHikersAgyHUD"
BUNDLE_DIR="$ROOT/dist/${APP_NAME}.app"
CONTENTS="$BUNDLE_DIR/Contents"

echo "[1/4] Building Swift release binary (Command Line Tools compatible)..."
cd "$ROOT"
SDK_PATH="$(xcrun --show-sdk-path)"
ARCH="$(uname -m)"
mkdir -p "$ROOT/.build/release"
BIN_PATH="$ROOT/.build/release/${APP_NAME}"
swiftc -O \
  -sdk "$SDK_PATH" \
  -target "${ARCH}-apple-macosx13.0" \
  "$ROOT"/Sources/MindHikersAgyHUD/*.swift \
  -o "$BIN_PATH"

if [[ ! -x "$BIN_PATH" ]]; then
  echo "Error: built binary not found at $BIN_PATH" >&2
  exit 1
fi

echo "[2/4] Assembling .app bundle at $BUNDLE_DIR..."
rm -rf "$BUNDLE_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$BIN_PATH" "$CONTENTS/MacOS/${APP_NAME}"
cp "$ROOT/Resources/hud_parser.py" "$CONTENTS/Resources/hud_parser.py"
cp "$ROOT/Resources/context_report.py" "$CONTENTS/Resources/context_report.py"
chmod +x "$CONTENTS/MacOS/${APP_NAME}" "$CONTENTS/Resources/hud_parser.py"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>CFBundleExecutable</key>
  <string>MindHikersAgyHUD</string>
  <key>CFBundleIdentifier</key>
  <string>org.mindhikers.agy-hud</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>MindHikers AGY HUD</string>
  <key>CFBundleDisplayName</key>
  <string>MindHikers AGY HUD</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

echo "[3/4] Applying local ad-hoc code signature..."
codesign --force --deep --sign - "$BUNDLE_DIR" >/dev/null 2>&1 || true

echo "[4/4] Done! App bundle ready at:"
echo "  $BUNDLE_DIR"
echo "Run with: open \"$BUNDLE_DIR\""
