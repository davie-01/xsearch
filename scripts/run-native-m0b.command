#!/bin/bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
sample="${1:?用法：bash scripts/run-native-m0b.command 有文字层的参考PDF}"
bash scripts/run-xpc-bench.command
# Keep the reference path in ignored work/ so analyze-vision.py never embeds a sample name.
python3 -c 'import json,sys;print(json.dumps({"reference_pdf":sys.argv[1]},ensure_ascii=False))' "$sample" > work/m0b/vision-reference-private.json
work/m0b/VisionProbe "$sample" "$PWD/work/m0b/vision-user-session-private.json" 10
