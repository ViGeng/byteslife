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
    <string>0.9.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>ByteLife counts how many Bluetooth peripherals connect during the day. It never reads device names, addresses, or any data they carry.</string>
</dict>
</plist>
PLIST

# Input Monitoring (and every other TCC) grant binds to the code-signing identity. A stable, self-signed
# "ByteLife Local" identity in the keychain keeps those grants valid across rebuilds; ad-hoc signing mints
# a fresh identity every run, silently staling the old grant. Prefer the stable identity when present,
# otherwise fall back to ad hoc exactly as before. This script never creates a certificate.
IDENTITY_NAME="ByteLife Local"
if security find-identity -v -p codesigning | grep -q "\"$IDENTITY_NAME\""; then
    echo "==> Codesigning with keychain identity \"$IDENTITY_NAME\" (stable TCC grants)"
    codesign --force --sign "$IDENTITY_NAME" "$BUNDLE"
else
    echo "==> Codesigning ad hoc (no \"$IDENTITY_NAME\" identity in keychain; TCC grants will not persist across rebuilds)"
    codesign --force --sign - "$BUNDLE"
fi
codesign --verify --verbose "$BUNDLE"

echo "==> Done: ${BUNDLE}"
