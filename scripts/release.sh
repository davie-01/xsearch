#!/bin/bash
# Prepares a release for GitHub Releases (M5):
#   XS_GITHUB_REPO=owner/repo bash scripts/release.sh 0.2.0
# 1. sets the version (Info.plist of the app and of IndexService; build number + 1);
# 2. builds the DMG with the update feed
#    https://github.com/<repo>/releases/latest/download/appcast.xml;
# 3. signs it with the EdDSA key in the login Keychain (account "xsearch") and writes
#    appcast.xml covering every release kept in work/releases/.
# Upload work/releases/XSearch-<version>.dmg and work/releases/appcast.xml to a GitHub release
# tagged v<version> (mark it "latest"). XS_FEED_URL / XS_DOWNLOAD_PREFIX override the GitHub
# addresses (local testing).
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:?usage: release.sh <version>}"
repo="${XS_GITHUB_REPO:-}"
feed="${XS_FEED_URL:-${repo:+https://github.com/$repo/releases/latest/download/appcast.xml}}"
prefix="${XS_DOWNLOAD_PREFIX:-${repo:+https://github.com/$repo/releases/download/v$version/}}"
[ -n "$feed" ] && [ -n "$prefix" ] || { echo "set XS_GITHUB_REPO=owner/repo (or XS_FEED_URL and XS_DOWNLOAD_PREFIX)" >&2; exit 1; }
for plist in App/Resources/Info.plist App/IndexService/Info.plist; do
    build=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$plist")
    /usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $version" -c "Set CFBundleVersion $((build + 1))" "$plist"
done
XS_FEED_URL="$feed" bash scripts/build-dmg.sh
out="${XS_RELEASE_DIR:-work/releases}"
mkdir -p "$out"
cp "target/XSearch-$version.dmg" "$out/"
.tools/sparkle-2.10.0/bin/generate_appcast --account xsearch --download-url-prefix "$prefix" -o "$out/appcast.xml" "$out"
echo "Release files in $out: XSearch-$version.dmg, appcast.xml (feed: $feed)"
