#!/bin/bash
# Builds target/XSearch-<version>.dmg: the app (scripts/build-app.sh), an /Applications link
# for drag-to-install, and a 许可与源码 folder (licenses and where the corresponding source is).
# Without a Developer ID the app is signed with XS_SIGN_IDENTITY (or ad-hoc) and not notarized:
# on other Macs the first launch needs System Settings → Privacy & Security → Open Anyway.
# XS_SOURCE_URL: download address of the corresponding source (release.sh sets it).
# XS_NOTARY_PROFILE: a `xcrun notarytool store-credentials` profile; when set (with a
# Developer ID Application identity in XS_SIGN_IDENTITY) the DMG is notarized and stapled.
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build-app.sh
app="$PWD/target/XSearch.app"
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")
stage="$PWD/target/dmg-stage"
dmg="$PWD/target/XSearch-$version.dmg"
rm -rf "$stage" "$dmg"
mkdir -p "$stage"
# ditto keeps the code signature and extended attributes intact.
ditto "$app" "$stage/XSearch.app"
ln -s /Applications "$stage/Applications"
docs="$stage/许可与源码"
mkdir -p "$docs"
cp "$app/Contents/Resources/Licenses/"* "$docs/"
source_url="${XS_SOURCE_URL:-本项目 GitHub 仓库 Releases 页面中同一版本的 XSearch-$version-source.tar.gz}"
cat > "$docs/对应源码.txt" <<EOF
XSearch ${version} 以 GNU 通用公共许可证第 3 版（LICENSE）发布，附 UnRAR 链接例外
（XSearch-UnRAR-linking-exception.md）。

本版本的对应源码，包括构建脚本以及链接进应用的全部 Rust 依赖源码（含 UnRAR 源码），
可从以下地址获取：

$source_url

第三方组件的许可见 THIRD_PARTY_NOTICES.md、UnRAR-license.txt 与 Rust-crates.txt。
EOF
hdiutil create -volname "XSearch $version" -srcfolder "$stage" -fs APFS -format UDZO -ov "$dmg" >/dev/null
rm -rf "$stage"
if [ -n "${XS_NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$dmg" --keychain-profile "$XS_NOTARY_PROFILE" --wait
    xcrun stapler staple "$dmg"
fi
# The copy inside the image must still verify.
mnt=$(mktemp -d)
hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$dmg" >/dev/null
codesign --verify --strict --deep "$mnt/XSearch.app" && echo "signature ok inside the image"
diskutil eject "$mnt" >/dev/null
rmdir "$mnt"
echo "Built $dmg ($(du -h "$dmg" | cut -f1))"
