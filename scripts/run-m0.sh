#!/bin/bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
source scripts/env.sh
sample="${1:?Usage: bash scripts/run-m0.sh READ_ONLY_SAMPLE_DIRECTORY}"
mkdir -p work/m0
run="$PWD/work/m0/runs/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$run"
python3 scripts/fixtures.py
cargo fmt --all -- --check
cargo test --workspace --locked >work/m0/tests-final.log 2>&1
cargo build --release --locked
bash scripts/build-native.sh >work/m0/native-build.log 2>&1
python3 scripts/extraction-probe.py "$sample"
target/release/xs validate "$run/validation" work/m0/real-corpus.json >work/m0/validation-final.json
target/release/xs benchmark "$run/benchmark" work/m0/real-corpus.json >work/m0/benchmark-final.json
python3 scripts/unicode-crosscheck.py
python3 scripts/native-checks.py "$sample"
python3 scripts/m0-gate.py
