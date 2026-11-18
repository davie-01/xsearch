#!/bin/bash
# Corresponding source of a release (GPLv3 §6 and the UnRAR linking exception): the tree at
# tag v<version> plus every Rust dependency vendored — UnRAR's C++ source comes with
# unrar_sys — so the archive builds without crates.io. Sparkle (MIT) is still downloaded by
# scripts/fetch-sparkle.sh.
#   bash scripts/source-archive.sh 0.2.0      # → work/source/XSearch-0.2.0-source.tar.gz
# Kept out of work/releases/: generate_appcast would take a .tar.gz there for an update.
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:?usage: source-archive.sh <version>}"
tag="v$version"
git rev-parse -q --verify "refs/tags/$tag" >/dev/null || { echo "tag $tag not found" >&2; exit 1; }
source scripts/env.sh
out="${XS_SOURCE_DIR:-work/source}"
name="XSearch-$version-source"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git archive --format=tar --prefix="$name/" "$tag" | tar -x -C "$tmp"
mkdir -p "$tmp/$name/.cargo"
(cd "$tmp/$name" && cargo vendor --locked --versioned-dirs vendor > .cargo/config.toml)
cat > "$tmp/$name/SOURCE.md" <<EOF
# XSearch ${version} 对应源码

本目录为 XSearch ${version}（tag \`${tag}\`）的完整源码。\`vendor/\` 收录 \`Cargo.lock\` 锁定的全部
Rust 依赖源码，UnRAR 源码位于 \`vendor/unrar_sys-*/vendor/unrar/\`；\`.cargo/config.toml\`
让 Cargo 直接使用这些副本，无需访问 crates.io。构建步骤见 README.md 的“从源码构建”。
Sparkle 框架仍由 \`scripts/fetch-sparkle.sh\` 按固定版本下载并校验。
EOF
mkdir -p "$out"
tar -czf "$out/$name.tar.gz" -C "$tmp" "$name"
echo "Built $out/$name.tar.gz ($(du -h "$out/$name.tar.gz" | cut -f1))"
