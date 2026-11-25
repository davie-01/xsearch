#!/bin/bash
# Prepares a release for GitHub Releases (M5):
#   XS_GITHUB_REPO=owner/repo bash scripts/release.sh 0.2.0
# 1. sets the version (Info.plist of the app and of IndexService; build number + 1);
# 2. builds the DMG with the update feed
#    https://github.com/<repo>/releases/latest/download/appcast.xml;
# 3. signs it with the EdDSA key in the login Keychain (account "xsearch") and writes
#    appcast.xml covering every release kept in work/releases/.
# 4. points every older DMG in the appcast back at its own release (generate_appcast gives
#    them the new prefix, where they don't exist) and lists the files to upload, deltas included.
# The app is built slim (shared Rust library, stripped binaries); build-app.sh fails otherwise.
# Then commit the version change, tag it v<version>, and run scripts/source-archive.sh <version>
# for the corresponding source. Upload the listed files and work/source/XSearch-<version>-source.tar.gz
# to a GitHub release tagged v<version> (mark it "latest"). XS_FEED_URL / XS_DOWNLOAD_PREFIX
# override the GitHub addresses (local testing).
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:?usage: release.sh <version>}"
repo="${XS_GITHUB_REPO:-}"
feed="${XS_FEED_URL:-${repo:+https://github.com/$repo/releases/latest/download/appcast.xml}}"
prefix="${XS_DOWNLOAD_PREFIX:-${repo:+https://github.com/$repo/releases/download/v$version/}}"
[ -n "$feed" ] && [ -n "$prefix" ] || { echo "set XS_GITHUB_REPO=owner/repo (or XS_FEED_URL and XS_DOWNLOAD_PREFIX)" >&2; exit 1; }
for plist in App/Resources/Info.plist App/IndexService/Info.plist; do
    build=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$plist")
    /usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $version" -c "Set CFBundleVersion $((build + 1))" "$plist"
done
XS_FEED_URL="$feed" XS_SOURCE_URL="${XS_SOURCE_URL:-${prefix}XSearch-$version-source.tar.gz}" bash scripts/build-dmg.sh
out="${XS_RELEASE_DIR:-work/releases}"
mkdir -p "$out"
cp "target/XSearch-$version.dmg" "$out/"
.tools/sparkle-2.10.0/bin/generate_appcast --account xsearch --download-url-prefix "$prefix" -o "$out/appcast.xml" "$out"
# Older DMGs live in their own releases: <prefix with v$version>XSearch-<old>.dmg → v<old>.
# The feed itself is not signed (each enclosure carries its own EdDSA signature), so this is safe.
python3 -I - "$out/appcast.xml" "$prefix" "$version" <<'PY'
import re, sys
path, prefix, version = sys.argv[1:]
xml = open(path).read()
def own(m):
    old = m.group(1)
    return prefix.replace("v" + version, "v" + old) + "XSearch-" + old + ".dmg"
xml = re.sub(re.escape(prefix) + r"XSearch-([0-9][0-9.]*)\.dmg", lambda m: m.group(0) if m.group(1) == version else own(m), xml)
open(path, "w").write(xml)
PY
uploads=("$out/XSearch-$version.dmg" "$out/appcast.xml")
for f in $(grep -o "${prefix}[^\"]*\.delta" "$out/appcast.xml" | sed "s|^$prefix||" | sort -u); do uploads+=("$out/$f"); done
echo "Release files (feed: $feed):"
printf '  %s\n' "${uploads[@]}"
echo "Next: commit, tag v$version, bash scripts/source-archive.sh $version, then upload the files above and the source archive"
