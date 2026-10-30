#!/bin/bash
# Builds XSearch.app (M1): Rust normalizer → SwiftPM release → bundle → sign.
# XS_SIGN_IDENTITY: Apple Development identity; ad-hoc ("-") when unset.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
cargo build --release --locked -p xs-core
swift build -c release --scratch-path target/swift --product XSearch
app="$PWD/target/XSearch.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp App/Resources/Info.plist "$app/Contents/Info.plist"
cp "$(swift build -c release --scratch-path target/swift --show-bin-path)/XSearch" "$app/Contents/MacOS/XSearch"
codesign --force --sign "${XS_SIGN_IDENTITY:--}" --options runtime --timestamp=none "$app"
codesign --verify --strict "$app"
echo "Built $app"
