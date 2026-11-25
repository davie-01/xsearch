#!/usr/bin/env python3
# Writes the license texts of every Rust crate linked into libxs_ffi.dylib (normal and build
# dependencies of xs-ffi for aarch64-apple-darwin) to one file, for the app bundle and the DMG.
#   python3 -I scripts/collect-licenses.py <output.txt>
# Run after `source scripts/env.sh` and a build, so the crate sources are unpacked.
import json, pathlib, subprocess, sys

out = pathlib.Path(sys.argv[1])
tree = subprocess.run(['cargo', 'tree', '-p', 'xs-ffi', '-e', 'normal,build', '--target', 'aarch64-apple-darwin',
                       '--prefix', 'none', '-f', '{p}', '--locked'], check=True, capture_output=True, text=True).stdout
wanted = {tuple(line.split(' (')[0].split(' v', 1)) for line in tree.splitlines() if line and ' v' in line}
meta = json.loads(subprocess.run(['cargo', 'metadata', '--format-version', '1', '--locked'],
                                 check=True, capture_output=True, text=True).stdout)
prefixes = ('license', 'licence', 'copying', 'notice', 'unlicense')
parts, missing = [], []
for pkg in sorted(meta['packages'], key=lambda p: (p['name'], p['version'])):
    if pkg['source'] is None or (pkg['name'], pkg['version']) not in wanted:
        continue
    root = pathlib.Path(pkg['manifest_path']).parent
    files = sorted(f for f in root.iterdir() if f.is_file() and f.name.lower().startswith(prefixes))
    if pkg['name'] == 'unrar_sys':
        files.append(root / 'vendor' / 'unrar' / 'license.txt')
    header = f"{pkg['name']} {pkg['version']} — {pkg.get('license') or 'see files'}"
    if not files:
        missing.append(header)
        parts.append(f"{'=' * 78}\n{header}\n(No license file in the published crate; the license is stated in its Cargo.toml.)\n")
        continue
    for f in files:
        parts.append(f"{'=' * 78}\n{header}\n{f.relative_to(root)}\n{'-' * 78}\n{f.read_text(errors='replace').strip()}\n")
out.write_text('Rust crates linked into XSearch (libxs_ffi.dylib) and their license texts.\n'
               'The itemised list with links is THIRD_PARTY_NOTICES.md.\n\n' + '\n'.join(parts))
print(f"{out}: {len(parts)} texts, {len(missing)} crates without a license file")
