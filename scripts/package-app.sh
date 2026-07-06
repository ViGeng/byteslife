#!/usr/bin/env bash
# Builds a release binary and assembles a minimal, ad-hoc-signed ByteLife.app menubar bundle under
# dist/. Re-runnable: the old bundle is removed first. The bundle is a LSUIElement agent (no Dock
# icon), which is also what grants the stable, signed identity the Input Monitoring TCC prompt binds to.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

APP_NAME="ByteLife"
EXECUTABLE="ByteLifeApp"
BUNDLE="dist/${APP_NAME}.app"
CONTENTS="${BUNDLE}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"

echo "==> Building release binary"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/${EXECUTABLE}"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "error: built binary not found at $BIN_PATH" >&2
    exit 1
fi

echo "==> Assembling ${BUNDLE}"
rm -rf "$BUNDLE"
mkdir -p "$MACOS_DIR"
cp "$BIN_PATH" "${MACOS_DIR}/${EXECUTABLE}"

cat > "${CONTENTS}/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.vigeng.bytelife</string>
    <key>CFBundleName</key>
    <string>ByteLife</string>
    <key>CFBundleExecutable</key>
    <string>ByteLifeApp</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>CFBundleShortVersionString</key>
    <string>0.2.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
</dict>
</plist>
PLIST

echo "==> Ad-hoc codesigning"
codesign --force --sign - "$BUNDLE"
codesign --verify --verbose "$BUNDLE"

echo "==> Done: ${BUNDLE}"
