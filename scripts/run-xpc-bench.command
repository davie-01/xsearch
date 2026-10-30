#!/bin/bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
work/m0b/LatencyProbe.app/Contents/MacOS/LatencyProbe "$PWD/work/m0b/xpc-user-session.json" > work/m0b/xpc-user-session.stdout 2> work/m0b/xpc-user-session.stderr
python3 - <<'PY'
import json
r=json.load(open('work/m0b/xpc-user-session.json'))
print('XPC 往返测试：'+r['status'])
for row in r.get('rows',[]):print('第 %s 轮，%s 字节，P95 %.2f 微秒'%(row['round']+1,row['payload_bytes'],row['xpc']['p95_us']))
PY
