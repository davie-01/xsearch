#!/bin/bash
# Swift unit and end-to-end tests (name engine, catalog, real FSEvents in temporary folders).
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
cargo build --release --locked -p xs-ffi
swift test --scratch-path target/swift "$@"
