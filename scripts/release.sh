#!/bin/bash
# Publishes a ByteLife release so anyone can install it with
#   brew tap vigeng/tap && brew install --cask bytelife
#
# The flow: build and package the app, zip it with ditto (preserves the bundle exactly), create a
# GitHub release on the byteslife repo itself carrying the zip, then update Casks/bytelife.rb in the
# public homebrew-tap to point at that asset with the fresh sha256. Because byteslife is a public
# repo, its release assets download publicly, so the release lives on the app's own repo (the
# conventional layout) rather than being smuggled onto the tap. The tap only carries the cask.
#
# The cask clears the Gatekeeper quarantine with an `xattr -cr` postflight, since the app is ad-hoc
# signed and not notarized. Re-running for an already-published version fails at release creation by
# design; bump the version in package-app.sh first.
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCE_REPO="ViGeng/byteslife"
TAP_REPO="ViGeng/homebrew-tap"

VERSION=$(awk '/CFBundleShortVersionString/{getline; gsub(/.*<string>|<\/string>.*/,""); print; exit}' scripts/package-app.sh)
[ -n "$VERSION" ] || { echo "error: could not read version from scripts/package-app.sh" >&2; exit 1; }
TAG="v$VERSION"
ZIP="dist/ByteLife-$VERSION.zip"

echo "==> Packaging ByteLife $VERSION"
./scripts/package-app.sh

echo "==> Zipping"
rm -f "$ZIP"
ditto -c -k --keepParent dist/ByteLife.app "$ZIP"
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
echo "    sha256 $SHA"

echo "==> Creating release $TAG on $SOURCE_REPO"
gh release create "$TAG" "$ZIP" \
    --repo "$SOURCE_REPO" \
    --title "ByteLife $VERSION" \
    --notes "ByteLife $VERSION — a menu bar dashboard that tracks your digital life in bytes.

Install:
\`\`\`
brew tap vigeng/tap
brew install --cask bytelife
\`\`\`
The cask clears the Gatekeeper quarantine automatically. If your Homebrew sets \`HOMEBREW_REQUIRE_TAP_TRUST\`, run \`brew trust vigeng/tap\` once after tapping.

Installing the zip by hand instead? The app is ad-hoc signed and not notarized, so remove the quarantine attribute yourself: \`xattr -cr /Applications/ByteLife.app\`."

echo "==> Writing Casks/bytelife.rb in $TAP_REPO"
CASK=$(cat <<CASK_EOF
cask "bytelife" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/ViGeng/byteslife/releases/download/v#{version}/ByteLife-#{version}.zip"
  name "ByteLife"
  desc "Menu bar dashboard tracking your digital life in bytes"
  homepage "https://github.com/ViGeng/byteslife"

  depends_on macos: :sonoma

  app "ByteLife.app"

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-cr", "#{appdir}/ByteLife.app"],
                   sudo: false
  end

  zap trash: [
    "~/Library/Application Support/ByteLife",
    "~/Library/Preferences/com.vigeng.bytelife.plist",
    "~/Library/Saved Application State/com.vigeng.bytelife.savedState",
  ]
end
CASK_EOF
)
EXISTING_SHA=$(gh api "repos/$TAP_REPO/contents/Casks/bytelife.rb" -q .sha 2>/dev/null || true)
gh api -X PUT "repos/$TAP_REPO/contents/Casks/bytelife.rb" \
    -f message="bytelife $VERSION" \
    -f content="$(printf '%s\n' "$CASK" | base64 | tr -d '\n')" \
    ${EXISTING_SHA:+-f sha="$EXISTING_SHA"} > /dev/null

echo "==> Done: brew tap vigeng/tap && brew install --cask bytelife"
