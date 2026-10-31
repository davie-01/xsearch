#!/bin/bash
# Builds target/XSearch-<version>.dmg: the app (scripts/build-app.sh) and an /Applications link
# for drag-to-install. Without a Developer ID the app is signed with XS_SIGN_IDENTITY (or
# ad-hoc) and not notarized: on other Macs it opens with right-click → 打开 the first time.
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build-app.sh
app="$PWD/target/XSearch.app"
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")
stage="$PWD/target/dmg-stage"
dmg="$PWD/target/XSearch-$version.dmg"
rm -rf "$stage" "$dmg"
mkdir -p "$stage"
# ditto keeps the code signature and extended attributes intact.
ditto "$app" "$stage/XSearch.app"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "XSearch $version" -srcfolder "$stage" -fs APFS -format UDZO -ov "$dmg" >/dev/null
rm -rf "$stage"
# The copy inside the image must still verify.
mnt=$(mktemp -d)
hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$dmg" >/dev/null
codesign --verify --strict --deep "$mnt/XSearch.app" && echo "signature ok inside the image"
diskutil eject "$mnt" >/dev/null
rmdir "$mnt"
echo "Built $dmg ($(du -h "$dmg" | cut -f1))"
