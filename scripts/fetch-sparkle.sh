#!/bin/bash
# Fetches Sparkle (auto-update, MIT) into .tools/ once, verified against the SHA-256 that
# GitHub publishes for the release asset. No global installation.
set -euo pipefail
cd "$(dirname "$0")/.."
version=2.10.0
sha=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
dir=".tools/sparkle-$version"
[ -d "$dir/Sparkle.framework" ] && exit 0
mkdir -p .tools/sparkle-dl "$dir"
archive=".tools/sparkle-dl/Sparkle-$version.tar.xz"
curl -sSL -o "$archive" "https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-$version.tar.xz"
echo "$sha  $archive" | shasum -a 256 -c -
tar -xJf "$archive" -C "$dir"
