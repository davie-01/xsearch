#!/bin/bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
source scripts/env.sh
mkdir -p work/m0b
swiftc -O -swift-version 6 -target arm64-apple-macosx26.0 -module-cache-path "$SWIFT_MODULECACHE_PATH" -framework AppKit -framework PDFKit -framework Vision -framework ImageIO native/m0b/VisionProbe.swift -o work/m0b/VisionProbe
