#!/bin/bash
# Builds XSearch.app: Rust engine → SwiftPM release → bundle (app, xs-extract worker,
# IndexService.xpc) → sign inside-out.
# XS_SIGN_IDENTITY: Apple Development identity; ad-hoc ("-") when unset.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
bash scripts/fetch-sparkle.sh
cargo build --release --locked -p xs-ffi
swift build -c release --scratch-path target/swift --product XSearch
swift build -c release --scratch-path target/swift --product xs-extract
swift build -c release --scratch-path target/swift --product IndexService
app="$PWD/target/XSearch.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp App/Resources/Info.plist "$app/Contents/Info.plist"
cp App/Resources/XSearch.icns App/Resources/XSearchTemplate-18.png App/Resources/XSearchTemplate-18@2x.png "$app/Contents/Resources/"
# Auto-update: the public EdDSA key always; the feed only when XS_FEED_URL is given (e.g.
# https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml). No feed = updates off.
/usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $(cat App/Resources/sparkle-public-key.txt)" "$app/Contents/Info.plist"
if [ -n "${XS_FEED_URL:-}" ]; then
    /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $XS_FEED_URL" "$app/Contents/Info.plist"
fi
mkdir -p "$app/Contents/Frameworks"
ditto .tools/sparkle-2.10.0/Sparkle.framework "$app/Contents/Frameworks/Sparkle.framework"
bin="$(swift build -c release --scratch-path target/swift --show-bin-path)"
cp "$bin/XSearch" "$app/Contents/MacOS/XSearch"
cp "$bin/xs-extract" "$app/Contents/MacOS/xs-extract"
xpc="$app/Contents/XPCServices/IndexService.xpc"
mkdir -p "$xpc/Contents/MacOS"
cp App/IndexService/Info.plist "$xpc/Contents/Info.plist"
cp "$bin/IndexService" "$xpc/Contents/MacOS/IndexService"
# Inside-out signing: Sparkle's helpers and framework, the worker and the XPC service, then the app.
sparkle_fw="$app/Contents/Frameworks/Sparkle.framework"
for helper in "$sparkle_fw/Versions/B/XPCServices/Installer.xpc" "$sparkle_fw/Versions/B/XPCServices/Downloader.xpc" \
              "$sparkle_fw/Versions/B/Autoupdate" "$sparkle_fw/Versions/B/Updater.app"; do
    [ -e "$helper" ] && codesign --force --sign "${XS_SIGN_IDENTITY:--}" --options runtime --timestamp=none "$helper"
done
codesign --force --sign "${XS_SIGN_IDENTITY:--}" --options runtime --timestamp=none "$sparkle_fw"
codesign --force --sign "${XS_SIGN_IDENTITY:--}" --options runtime --timestamp=none "$app/Contents/MacOS/xs-extract"
codesign --force --sign "${XS_SIGN_IDENTITY:--}" --options runtime --timestamp=none "$xpc"
codesign --force --sign "${XS_SIGN_IDENTITY:--}" --options runtime --timestamp=none --entitlements App/Resources/XSearch.entitlements "$app"
codesign --verify --strict "$app"
echo "Built $app"
