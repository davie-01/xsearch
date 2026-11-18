#!/bin/bash
# Indexing mode comparison (2c): time to index the same documents through the real app and
# IndexService in each mode, with peak memory and, with --energy, CPU energy from powermetrics.
# Quit XSearch first: the script starts throwaway instances and kills them afterwards.
#   bash scripts/bench-indexing-mode.sh            # 600 documents, timing and memory
#   sudo -v && bash scripts/bench-indexing-mode.sh --energy 600
# Documents: plain text (mixed Chinese and English), .docx (textutil) and .pdf (cupsfilter).
set -uo pipefail
cd "$(dirname "$0")/.."
energy=0
[ "${1:-}" = "--energy" ] && { energy=1; shift; }
count=${1:-600}
app=target/XSearch.app/Contents/MacOS/XSearch
[ -x "$app" ] || { echo "build the app first: scripts/build-app.sh"; exit 1; }
if pgrep -f "XSearch.app/Contents/MacOS/XSearch" >/dev/null; then echo "quit XSearch first"; exit 1; fi
root=$(mktemp -d "${TMPDIR:-/tmp}/xs-bench-mode.XXXX")
trap 'rm -rf "$root"; pkill -f "XSearch.app/Contents" 2>/dev/null; [ -n "${pm:-}" ] && sudo -n kill "$pm" 2>/dev/null' EXIT

echo "generating $count documents…"
mkdir -p "$root/docs"
python3 -I - "$root/docs" "$count" <<'PY'
import random, sys
random.seed(7)
words = ("合同 验收 支付 条件 报告 年度 项目 系统 测试 部署 接口 数据 安全 管理 服务 计划 "
         "contract invoice report system deploy service data network budget review schedule").split()
for i in range(int(sys.argv[2])):
    body = "\n".join(" ".join(random.choice(words) for _ in range(random.randint(8, 30))) for _ in range(random.randint(200, 2500)))
    with open(f"{sys.argv[1]}/doc{i:04d}.txt", "w") as f:
        f.write(f"needle{i}\n{body}\n")
PY
# A quarter as .docx, a tenth as .pdf (their own parsers: zip + XML, PDFKit).
n=0
for f in "$root"/docs/*.txt; do
    n=$((n + 1))
    if [ $((n % 4)) -eq 0 ]; then textutil -convert docx "$f" -output "${f%.txt}.docx" && rm "$f"
    elif [ $((n % 10)) -eq 1 ]; then cupsfilter "$f" > "${f%.txt}.pdf" 2>/dev/null && rm "$f"; fi
done
echo "documents: $(ls "$root/docs" | wc -l | tr -d ' ') ($(du -sh "$root/docs" | cut -f1 | tr -d ' '))"

printf '\n%-12s %8s %8s %10s %10s\n' mode seconds indexed peakMB cpuJ
for mode in performance balanced quiet; do
    T="$root/$mode"; mkdir -p "$T/data"
    pm=""
    if [ $energy = 1 ]; then
        sudo -n powermetrics -i 1000 --samplers cpu_power -o "$T/power.txt" >/dev/null 2>&1 &
        pm=$!
    fi
    XS_INDEXING_MODE=$mode XS_DATA_DIR="$T/data" XS_NAME_ROOTS="$root/docs" XS_CONTENT_ROOTS="$root/docs" "$app" >/dev/null 2>&1 &
    pid=$!; start=$(python3 -c "import time; print(time.time())"); peak=0; settled=0
    while :; do
        sleep 0.5
        rss=$(ps -A -o rss=,comm= | awk '/IndexService|xs-extract/{t+=$1} END{print t+0}')
        [ "$rss" -gt "$peak" ] && peak=$rss
        c=$(sqlite3 "$T/data/catalog.sqlite" "select (select count(*) from content_tasks), (select count(*) from files where in_content=1)" 2>/dev/null)
        if [ "${c%%|*}" = "0" ] && [ "${c##*|}" -gt 0 ] 2>/dev/null; then settled=$((settled + 1)); [ $settled -ge 3 ] && break; else settled=0; fi
        [ $(( $(date +%s) - ${start%.*} )) -gt 1800 ] && { echo "$mode: no end after 30 min"; break; }
    done
    secs=$(python3 -c "import time; print(f'{time.time() - $start - 1.5:.1f}')")
    indexed=$(sqlite3 "$T/data/catalog.sqlite" "select count(*) from files where in_content=1 and content_state in (1,2,3)")
    joules="-"
    if [ -n "$pm" ]; then
        sudo -n kill "$pm" 2>/dev/null; wait "$pm" 2>/dev/null; pm=""
        joules=$(awk '/^CPU Power:/{s+=$3; n++} END{if(n) printf "%.0f", s/1000; else print "-"}' "$T/power.txt")
    fi
    printf '%-12s %8s %8s %10s %10s\n' "$mode" "$secs" "$indexed" "$((peak / 1024))" "$joules"
    kill $pid 2>/dev/null; wait $pid 2>/dev/null; sleep 2; pkill -f "XSearch.app/Contents" 2>/dev/null; sleep 1
done
