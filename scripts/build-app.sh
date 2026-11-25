#!/bin/bash
# Builds XSearch.app: Rust engine → SwiftPM release → bundle (app, xs-extract worker,
# IndexService.xpc) → sign inside-out.
# XS_SIGN_IDENTITY: Apple Development identity; ad-hoc ("-") when unset.
# XS_NOTARY_PROFILE (see build-dmg.sh): signatures then carry a secure timestamp, which
# notarization requires.
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
cp App/Resources/XSearchTemplate-18.png App/Resources/XSearchTemplate-18@2x.png "$app/Contents/Resources/"
# Localizations (permission prompts; the UI strings live in code). Their presence also lets
# the system and Sparkle pick English when the language setting asks for it.
cp -R App/Resources/en.lproj App/Resources/zh-Hans.lproj "$app/Contents/Resources/"
# Licenses travel with the binary (GPLv3 §4–6): GPLv3, the UnRAR linking exception, UnRAR's
# license, the third-party notices and the license texts of every linked Rust crate.
mkdir -p "$app/Contents/Resources/Licenses"
cp LICENSE THIRD_PARTY_NOTICES.md LICENSES/* "$app/Contents/Resources/Licenses/"
python3 -I scripts/collect-licenses.py "$app/Contents/Resources/Licenses/Rust-crates.txt"
# An Icon Composer document: the only source format that keeps the dark variant on macOS.
xcrun actool App/Resources/AppIcon.icon --compile "$app/Contents/Resources" --platform macosx --minimum-deployment-target 26.0 \
    --app-icon AppIcon --output-partial-info-plist "$(mktemp)" > /dev/null
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
# One shared Rust library for all three executables (it used to be linked into each).
# Each finds it through an rpath into Contents/Frameworks; the development rpath to
# target/release that SwiftPM linked in is removed.
rust_lib="$app/Contents/Frameworks/libxs_ffi.dylib"
cp target/release/libxs_ffi.dylib "$rust_lib"
xs_extract="$app/Contents/MacOS/xs-extract"
index_service="$xpc/Contents/MacOS/IndexService"
for exe in "$app/Contents/MacOS/XSearch" "$xs_extract" "$index_service"; do
    install_name_tool -delete_rpath "$PWD/target/release" "$exe"
done
install_name_tool -add_rpath @executable_path/../Frameworks "$xs_extract"
install_name_tool -add_rpath @executable_path/../../../../Frameworks "$index_service"
# Debug symbols go to target/dsym (crash reports can still be symbolicated); the shipped
# binaries are stripped. The library keeps its exported symbols (-x).
dsym="$PWD/target/dsym"
rm -rf "$dsym"
mkdir -p "$dsym"
for f in "$app/Contents/MacOS/XSearch" "$xs_extract" "$index_service" "$rust_lib"; do
    dsymutil "$f" -o "$dsym/$(basename "$f").dSYM" 2>/dev/null || true
done
strip -S -x "$rust_lib"
for exe in "$app/Contents/MacOS/XSearch" "$xs_extract" "$index_service"; do
    strip "$exe"
done
# Inside-out signing: Sparkle's helpers and framework, the worker and the XPC service, then the app.
sparkle_fw="$app/Contents/Frameworks/Sparkle.framework"
ts="--timestamp=none"
if [ -n "${XS_NOTARY_PROFILE:-}" ]; then ts="--timestamp"; fi
for helper in "$sparkle_fw/Versions/B/XPCServices/Installer.xpc" "$sparkle_fw/Versions/B/XPCServices/Downloader.xpc" \
              "$sparkle_fw/Versions/B/Autoupdate" "$sparkle_fw/Versions/B/Updater.app"; do
    [ -e "$helper" ] && codesign --force --sign "${XS_SIGN_IDENTITY:--}" --options runtime $ts "$helper"
done
codesign --force --sign "${XS_SIGN_IDENTITY:--}" --options runtime $ts "$sparkle_fw"
codesign --force --sign "${XS_SIGN_IDENTITY:--}" --options runtime $ts "$rust_lib"
codesign --force --sign "${XS_SIGN_IDENTITY:--}" --options runtime $ts "$app/Contents/MacOS/xs-extract"
codesign --force --sign "${XS_SIGN_IDENTITY:--}" --options runtime $ts "$xpc"
codesign --force --sign "${XS_SIGN_IDENTITY:--}" --options runtime $ts --entitlements App/Resources/XSearch.entitlements "$app"
codesign --verify --strict "$app"
# Size gate: every build ships slim (see docs/DESIGN.md §6). Each executable loads the shared
# Rust library instead of carrying its own copy, and nothing ships with its symbol table.
for exe in "$app/Contents/MacOS/XSearch" "$xs_extract" "$index_service"; do
    otool -L "$exe" | grep -q "@rpath/libxs_ffi.dylib" || { echo "size gate: $exe does not load libxs_ffi.dylib" >&2; exit 1; }
    [ "$(nm -U "$exe" 2>/dev/null | wc -l)" -le 5 ] || { echo "size gate: $exe is not stripped" >&2; exit 1; }
    [ "$(nm -U "$exe" 2>/dev/null | grep -c '_ZN\|_R[0-9A-Z]')" -eq 0 ] || { echo "size gate: $exe contains Rust code" >&2; exit 1; }
done
[ "$(nm "$rust_lib" | grep -c ' [tsd] ')" -eq 0 ] || { echo "size gate: libxs_ffi.dylib keeps local symbols" >&2; exit 1; }
echo "Built $app ($(du -sh "$app" | cut -f1))"
