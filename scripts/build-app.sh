#!/bin/bash
# Builds XSearch.app (M1): Rust normalizer → SwiftPM release → bundle → sign.
# XS_SIGN_IDENTITY: Apple Development identity; ad-hoc ("-") when unset.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
cargo build --release --locked -p xs-ffi
swift build -c release --scratch-path target/swift --product XSearch
swift build -c release --scratch-path target/swift --product xs-extract
app="$PWD/target/XSearch.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp App/Resources/Info.plist "$app/Contents/Info.plist"
bin="$(swift build -c release --scratch-path target/swift --show-bin-path)"
cp "$bin/XSearch" "$app/Contents/MacOS/XSearch"
cp "$bin/xs-extract" "$app/Contents/MacOS/xs-extract"
# Inside-out signing: the worker first, then the app bundle.
codesign --force --sign "${XS_SIGN_IDENTITY:--}" --options runtime --timestamp=none "$app/Contents/MacOS/xs-extract"
codesign --force --sign "${XS_SIGN_IDENTITY:--}" --options runtime --timestamp=none --entitlements App/Resources/XSearch.entitlements "$app"
codesign --verify --strict "$app"
echo "Built $app"
