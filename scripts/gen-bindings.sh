#!/bin/bash
# Builds the Rust static library and regenerates the Swift bindings (UniFFI). Run after any
# change to rust/xs-ffi's exported API; the generated files are committed.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
cargo build --release --locked -p xs-ffi
out=target/uniffi
rm -rf "$out"
cargo run --release --locked -q -p xs-ffi --bin uniffi-bindgen -- \
  generate --library target/release/libxs_ffi.dylib --language swift --out-dir "$out"
cp "$out/xs_ffi.swift" Packages/ContentEngine/Sources/Generated.swift
cp "$out/xs_ffiFFI.h" Packages/ContentEngine/xs_ffiFFI/include/xs_ffiFFI.h
cat > Packages/ContentEngine/xs_ffiFFI/include/module.modulemap <<'MAP'
module xs_ffiFFI {
    header "xs_ffiFFI.h"
    export *
}
MAP
echo "bindings regenerated"
