#!/bin/bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
source scripts/env.sh
mkdir -p work/m0b
python3 scripts/prepare-store-instrumentation.py
cargo fmt --manifest-path bench/m0b/Cargo.toml -- --check
cargo test --manifest-path bench/m0b/Cargo.toml --locked --offline >work/m0b/tests-final.log 2>&1
cargo clippy --manifest-path bench/m0b/Cargo.toml --locked --offline --all-targets -- -D warnings >work/m0b/clippy-final.log 2>&1
cargo build --release --manifest-path bench/m0b/Cargo.toml --locked --offline
run="$PWD/work/m0b/runs/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$run"
# Run timed workloads sequentially. Do not run OCR/builds/other benchmarks concurrently.
target/release/xs-m0b names 100000 1000000 >work/m0b/names-final.json
target/release/xs-m0b storage "$run/store" "${1:-work/m0/real-corpus.json}" >work/m0b/storage-final.json
cargo test --workspace --locked >work/m0b/m0a-regression.log 2>&1
python3 scripts/m0b-evidence.py
