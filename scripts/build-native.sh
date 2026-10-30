#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
mkdir -p work/m0/bin work/m0/swift-cache work/m0/clang-cache
 cargo build --release --locked -p xs-core
cp native/m0/NativeProbe.swift work/m0/main.swift
swiftc -swift-version 6 -target arm64-apple-macosx26.0 -module-cache-path "$SWIFT_MODULECACHE_PATH" -framework AppKit -framework PDFKit -framework Security -framework SystemConfiguration -lc++ -lz -import-objc-header native/m0/XSearchCore.h work/m0/main.swift target/release/libxs_core.a -o work/m0/bin/NativeProbe
app="$PWD/work/m0/PermissionProbe.app"
service="$app/Contents/XPCServices/ExtractionProbe.xpc"
mkdir -p "$app/Contents/MacOS" "$service/Contents/MacOS"
python3 - "$app" "$service" <<'PY'
import plistlib,sys,pathlib
for root,name,identifier,kind in [(sys.argv[1],'PermissionProbe','org.xsearch.m0.PermissionProbe','APPL'),(sys.argv[2],'ExtractionProbe','org.xsearch.m0.ExtractionProbe','XPC!')]:
    d=dict(CFBundleExecutable=name,CFBundleIdentifier=identifier,CFBundlePackageType=kind,CFBundleVersion='1',CFBundleShortVersionString='0.0.1',LSMinimumSystemVersion='26.0')
    if kind=='XPC!':d['XPCService']={'ServiceType':'Application'}
    else:d['LSUIElement']=True
    with open(pathlib.Path(root)/'Contents/Info.plist','wb') as f:plistlib.dump(d,f)
PY
clang -fobjc-arc -fmodules -fmodules-cache-path="$CLANG_MODULE_CACHE_PATH" -mmacosx-version-min=26.0 -framework Foundation -DXS_CHILD native/m0/PermissionProbe.m -o "$service/Contents/MacOS/FileChild"
clang -fobjc-arc -fmodules -fmodules-cache-path="$CLANG_MODULE_CACHE_PATH" -mmacosx-version-min=26.0 -framework Foundation -DXS_SERVICE native/m0/PermissionProbe.m -o "$service/Contents/MacOS/ExtractionProbe"
clang -fobjc-arc -fmodules -fmodules-cache-path="$CLANG_MODULE_CACHE_PATH" -mmacosx-version-min=26.0 -framework Foundation native/m0/PermissionProbe.m -o "$app/Contents/MacOS/PermissionProbe"
identity="${XS_SIGN_IDENTITY:--}"
codesign --force --sign "$identity" --options runtime --timestamp=none "$service/Contents/MacOS/FileChild"
codesign --force --sign "$identity" --options runtime --timestamp=none "$service"
codesign --force --sign "$identity" --options runtime --timestamp=none "$app"
codesign --verify --deep --strict "$app"
echo "Native extraction and signed XPC probes built."
