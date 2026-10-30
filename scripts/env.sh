#!/bin/sh
# Source this file from the project root. No global toolchain/PATH changes.
export CARGO_HOME="$PWD/.tools/cargo"
export RUSTUP_HOME="$PWD/.tools/rustup"
export CARGO_TARGET_DIR="$PWD/target"
export PATH="$CARGO_HOME/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET=26.0
export CLANG_MODULE_CACHE_PATH="$PWD/work/m0/clang-cache"
export SWIFT_MODULECACHE_PATH="$PWD/work/m0/swift-cache"

