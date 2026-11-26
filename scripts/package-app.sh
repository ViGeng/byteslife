#!/usr/bin/env bash
# Builds a signed ByteLife bundle under dist/. Pass --dev to build and launch the local debug app.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

APP_NAME="ByteLife"
BUNDLE_ID="com.vigeng.bytelife"
CONFIGURATION="release"
case "$#:${1:-}" in
    0:) ;;
    1:--dev)
        APP_NAME="ByteLife Dev"
        BUNDLE_ID="com.vigeng.bytelife.dev"
        CONFIGURATION="debug"
        if [[ "${BYTELIFE_DEV_BUILD_LOCKED:-}" != 1 ]]; then
            mkdir -p dist
            exec /usr/bin/lockf -k dist/.bytelife-dev.lock \
                env BYTELIFE_DEV_BUILD_LOCKED=1 "$REPO_ROOT/scripts/package-app.sh" --dev
        fi
        ;;
    *)
        echo "Usage: $0 [--dev]" >&2
        exit 2
        ;;
esac

EXECUTABLE="ByteLifeApp"
BUNDLE="dist/${APP_NAME}.app"

echo "==> Building ${CONFIGURATION} binary"
swift build -c "$CONFIGURATION"

BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)/${EXECUTABLE}"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "error: built binary not found at $BIN_PATH" >&2
    exit 1
fi

echo "==> Assembling ${BUNDLE}"
mkdir -p dist
STAGING_DIR="$(mktemp -d dist/.bytelife.XXXXXX)"
trap 'rm -rf "$STAGING_DIR"' EXIT
STAGED_BUNDLE="${STAGING_DIR}/${APP_NAME}.app"
CONTENTS="${STAGED_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RESOURCES_DIR="${CONTENTS}/Resources"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BIN_PATH" "${MACOS_DIR}/${EXECUTABLE}"
cp assets/AppIcon.icns "${RESOURCES_DIR}/AppIcon.icns"

cat > "${CONTENTS}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>ByteLifeApp</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon.icns</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>CFBundleShortVersionString</key>
    <string>0.10.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>ByteLife counts how many Bluetooth peripherals connect during the day. It never reads device names, addresses, or any data they carry.</string>
    <key>NSLocationUsageDescription</key>
    <string>ByteLife uses this permission to read the connected Wi-Fi name and group your daily traffic on this Mac.</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>ByteLife uses this permission to read the connected Wi-Fi name and group your daily traffic on this Mac.</string>
</dict>
</plist>
PLIST

# Input Monitoring (and every other TCC) grant binds to the code-signing identity. A stable, self-signed
# "ByteLife Local" identity in the keychain keeps those grants valid across rebuilds. Ad hoc signatures
# can change when the binary changes. Prefer the stable identity when present,
# otherwise fall back to ad hoc exactly as before. This script never creates a certificate.
IDENTITY_NAME="ByteLife Local"
if security find-identity -v -p codesigning | grep -q "\"$IDENTITY_NAME\""; then
    echo "==> Codesigning with keychain identity \"$IDENTITY_NAME\" (stable TCC grants)"
    codesign --force --sign "$IDENTITY_NAME" "$STAGED_BUNDLE"
else
    echo "==> Codesigning ad hoc (macOS may ask for permissions again after a rebuild)"
    codesign --force --sign - "$STAGED_BUNDLE"
fi
codesign --verify --verbose "$STAGED_BUNDLE"

if [[ "$CONFIGURATION" == "debug" ]]; then
    # Quit the previous dev instance before replacing its bundle. Give it time to close its database.
    swift - "$BUNDLE_ID" <<'SWIFT'
import AppKit

let apps = NSRunningApplication.runningApplications(withBundleIdentifier: CommandLine.arguments[1])
for app in apps {
    _ = app.terminate()
}
let deadline = ProcessInfo.processInfo.systemUptime + 5
while apps.contains(where: { !$0.isTerminated }) {
    guard ProcessInfo.processInfo.systemUptime < deadline else {
        FileHandle.standardError.write(Data("Could not quit ByteLife Dev. The previous app is still running.\n".utf8))
        exit(1)
    }
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
}
SWIFT
fi

rm -rf "$BUNDLE"
mv "$STAGED_BUNDLE" "$BUNDLE"
echo "==> Done: ${BUNDLE}"

if [[ "$CONFIGURATION" == "debug" ]]; then
    open "$BUNDLE"
fi
