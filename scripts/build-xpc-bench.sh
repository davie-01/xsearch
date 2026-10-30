#!/bin/bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
source scripts/env.sh
app="$PWD/work/m0b/LatencyProbe.app"
service="$app/Contents/XPCServices/LatencyService.xpc"
mkdir -p "$app/Contents/MacOS" "$service/Contents/MacOS" work/m0b
python3 - "$app" "$service" <<'PY'
import plistlib,sys,pathlib
for path,name,identifier,kind in [(sys.argv[1],'LatencyProbe','org.xsearch.m0b.LatencyProbe','APPL'),(sys.argv[2],'LatencyService','org.xsearch.m0b.LatencyService','XPC!')]:
 d=dict(CFBundleExecutable=name,CFBundleIdentifier=identifier,CFBundlePackageType=kind,CFBundleVersion='1',CFBundleShortVersionString='0.0.1',LSMinimumSystemVersion='26.0')
 if kind=='XPC!':d['XPCService']={'ServiceType':'Application'}
 else:d['LSUIElement']=True
 with open(pathlib.Path(path)/'Contents/Info.plist','wb') as f:plistlib.dump(d,f)
PY
for role in service app; do
  if [[ "$role" == service ]]; then
    clang -fobjc-arc -fmodules -fmodules-cache-path="$CLANG_MODULE_CACHE_PATH" -mmacosx-version-min=26.0 -framework Foundation -DXS_SERVICE native/m0b/LatencyProbe.m -o "$service/Contents/MacOS/LatencyService"
  else
    clang -fobjc-arc -fmodules -fmodules-cache-path="$CLANG_MODULE_CACHE_PATH" -mmacosx-version-min=26.0 -framework Foundation native/m0b/LatencyProbe.m -o "$app/Contents/MacOS/LatencyProbe"
  fi
done
identity="${XS_SIGN_IDENTITY:--}"
codesign --force --sign "$identity" --options runtime --timestamp=none "$service"
codesign --force --sign "$identity" --options runtime --timestamp=none "$app"
codesign --verify --deep --strict "$app"
