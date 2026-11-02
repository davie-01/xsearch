#!/bin/bash
# Peak memory of indexing distinct texts through the real app and IndexService, in a throwaway
# data directory (generates about 20 MiB per file; quit XSearch first). Usage: bench-memory.sh 1 8 64
set -uo pipefail
cd "$(dirname "$0")/.."
root=$(mktemp -d "${TMPDIR:-/tmp}/xs-bench-memory.XXXX")
trap 'rm -rf "$root"; pkill -f "XSearch.app/Contents" 2>/dev/null' EXIT
for n in "$@"; do
    T="$root/$n"; mkdir -p "$T/data" "$T/docs"
    python3 -I - "$T/docs" "$n" <<'PY'
import binascii, os, sys
for i in range(int(sys.argv[2])):
    with open(f"{sys.argv[1]}/f{i}.txt", "wb") as f:
        f.write(b"needle\n"); f.write(binascii.hexlify(os.urandom(10 << 20)))
PY
    XS_DATA_DIR="$T/data" XS_NAME_ROOTS="$T/docs" XS_CONTENT_ROOTS="$T/docs" target/XSearch.app/Contents/MacOS/XSearch >/dev/null 2>&1 &
    app=$!; start=$(date +%s); service=0; workers=0; total=0; settled=0
    while [ $(( $(date +%s) - start )) -lt 300 ]; do
        sleep 0.3
        pid=$(pgrep -n -f "IndexService.xpc/Contents/MacOS"); s=0
        [ -n "$pid" ] && s=$(ps -o rss= -p "$pid" | tr -d ' ')
        w=$(ps -A -o rss=,comm= | awk '/xs-extract/{t+=$1} END{print t+0}')
        [ "${s:-0}" -gt "$service" ] && service=$s
        [ "$w" -gt "$workers" ] && workers=$w
        [ $(( ${s:-0} + w )) -gt "$total" ] && total=$(( ${s:-0} + w ))
        c=$(sqlite3 "$T/data/catalog.sqlite" "select (select count(*) from content_tasks), (select count(*) from files where in_content=1)" 2>/dev/null)
        if [ "$c" = "0|$n" ]; then settled=$((settled + 1)); [ $settled -ge 5 ] && break; else settled=0; fi
    done
    indexed=$(sqlite3 "$T/data/catalog.sqlite" "select count(*) from files where in_content=1 and content_state in (1,2,3)")
    echo "n=$n $(( $(date +%s) - start ))s indexed=$indexed service=$((service/1024))MB workers=$((workers/1024))MB total=$((total/1024))MB index=$(du -sh "$T/data/content" | cut -f1 | tr -d ' ')"
    kill $app 2>/dev/null; sleep 2; pkill -f "XSearch.app/Contents" 2>/dev/null; sleep 1; rm -rf "$T"
done
