#!/bin/bash
# Release regression gate (M5): correctness, then performance against docs/m5/perf-baseline.json.
#   bash scripts/regression.sh                  # check
#   bash scripts/regression.sh --update-baseline  # record the current machine's numbers
# Correctness: Rust tests (incl. brute-force comparisons in every match mode), clippy with
# warnings as errors, every Swift test. Performance (release builds, synthetic data with fixed
# seeds): name engine on 1,000,000 entries, content queries on 10,000 documents, extraction of
# the fixtures. Fails when a latency exceeds baseline × 1.5 (and by more than 5 ms), memory
# exceeds baseline × 1.2, or a synthetic hit count changes at all.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
out=work/regression
rm -rf "$out"
mkdir -p "$out"
step() { printf '\n== %s\n' "$1"; }

step "Rust tests"
# Success is the command's exit status; the log is only filtered for display.
if ! cargo test --release --locked -q > "$out/rust-test.log" 2>&1; then
    tail -40 "$out/rust-test.log"
    echo "Rust tests failed"
    exit 1
fi
grep -E "test result" "$out/rust-test.log" | grep -v " 0 passed" || true
step "clippy"
cargo clippy --release --locked -q --all-targets -- -D warnings

step "Swift tests"
cargo build --release --locked -q -p xs-ffi
# A failed build must stop here: --skip-build below would run the previous binaries.
if ! swift build --scratch-path target/swift --build-tests > "$out/swift-build.log" 2>&1; then
    grep -E "error:" "$out/swift-build.log" || tail -40 "$out/swift-build.log"
    echo "Swift build failed"
    exit 1
fi
perl -e 'alarm 900; exec @ARGV' swift test --scratch-path target/swift --skip-build > "$out/swift-test.log" 2>&1 || { tail -40 "$out/swift-test.log"; echo "Swift tests failed"; exit 1; }
grep -E "Test run with" "$out/swift-test.log"
grep -q "✘" "$out/swift-test.log" && { grep "✘" "$out/swift-test.log"; exit 1; }

step "Benchmark: name engine (1,000,000 entries)"
XS_BENCH=1 perl -e 'alarm 900; exec @ARGV' swift test -c release -Xswiftc -enable-testing --scratch-path target/swift \
    --filter benchMillionEntries > "$out/name-bench.log" 2>&1 || { tail -30 "$out/name-bench.log"; exit 1; }

step "Benchmark: content queries (10,000 documents)"
cargo run -q --release --locked -p xs-index --example bench -- "$out/content-index" 10000 > "$out/content-bench.json"
rm -rf "$out/content-index"

step "Benchmark: extraction"
if ! swift build -c release --scratch-path target/swift --product xs-extract > "$out/extract-build.log" 2>&1; then
    tail -40 "$out/extract-build.log"
    echo "xs-extract build failed"
    exit 1
fi
worker="$(swift build -c release --scratch-path target/swift --show-bin-path)/xs-extract"
python3 -I -c "
import random, sys
random.seed(7)
words = ['合同', '数据', '共享', 'report', 'budget', '的', '平台', '2024']
with open(sys.argv[1], 'w', encoding='utf-8') as f:
    for _ in range(400_000): f.write(' '.join(random.choice(words) for _ in range(8)) + '\n')
" "$out/large.txt"
"$worker" --probe Tests/Fixtures/m0/structure.docx Tests/Fixtures/m0/sample.txt "$out/large.txt" > "$out/extract.tsv"
rm -f "$out/large.txt"

step "Compare with baseline"
python3 -I scripts/perf_compare.py "$out" docs/m5/perf-baseline.json "$@"
