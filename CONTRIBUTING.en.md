[简体中文](CONTRIBUTING.md) · **English**

# Contributing to XSearch

Issues and changes are welcome. Before starting, read the [Design and Engineering Guide](docs/DESIGN.en.md): it explains the process structure, the two search paths and what each directory is for. Interface changes follow [docs/design/UI-SPEC.md](docs/design/UI-SPEC.md) (Chinese).

## Environment

- An Apple silicon Mac with macOS 26 or later
- A full Xcode (macOS 26 SDK, Swift 6.2 or later), with `xcode-select -p` pointing to it
- Rust stable. The project scripts keep the toolchain in `.tools/` through `scripts/env.sh` and leave the global PATH alone; install it as described in the README, or run the rustup installer after `source scripts/env.sh`

## Building and testing

```sh
source scripts/env.sh
cargo test --workspace --locked
cargo clippy --workspace --all-targets --locked -- -D warnings
bash scripts/fetch-sparkle.sh      # needed before the first Swift test run in a clean checkout
bash scripts/swift-test.sh
bash scripts/build-app.sh          # assembles target/XSearch.app (ad-hoc signed without XS_SIGN_IDENTITY)
```

During development, use `XS_DATA_DIR` for a separate data folder so your everyday index is left alone, and `XS_LANG=en` to launch in English. For changes that affect query or indexing performance, run `bash scripts/regression.sh` before submitting.

The hotkey, permission prompts (TCC), the XPC service and auto-update can only be verified in a normal desktop session: build the app, launch it from Finder, try what your change touches, and describe the steps and results in the PR.

## Commit conventions

- One change per commit. Write the subject in English as `Module: one sentence describing the behavior`, e.g. `Catalog: purging tombstones never frees the highest file id`; explain the reason in the body when it needs explaining.
- Query syntax changes update the search guide ([Chinese](docs/SEARCH-GUIDE.md) and [English](docs/SEARCH-GUIDE.en.md)); new or upgraded dependencies update [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md); user-facing changes go into the changelog ([Chinese](CHANGELOG.md) and [English](CHANGELOG.en.md)).
- Documents with an English version (`*.en.md`) are changed in both languages together.
- Chinese is the source language of the interface; see [docs/design/LOCALIZATION.md](docs/design/LOCALIZATION.md) (Chinese) for how strings are written and translated.
- Test fixtures use synthetic data only; never commit real documents, real paths or personal indexes.

## License

XSearch is released under GPLv3 with an UnRAR linking exception. By contributing code you agree to license your contribution under the same terms, including the [UnRAR linking exception](LICENSES/XSearch-UnRAR-linking-exception.md).

## Releasing (maintainers)

1. `XS_SIGN_IDENTITY='…' XS_GITHUB_REPO='davie-01/xsearch' bash scripts/release.sh <version>`: sets the version, builds the slim DMG (with licenses and the source notice; a failed size gate stops it), writes the signed `appcast.xml`, fixes the addresses of earlier versions and lists the files to upload.
2. Commit the version change, tag it `v<version>`, and push `main` and the tag.
3. `bash scripts/source-archive.sh <version>`: builds `work/source/XSearch-<version>-source.tar.gz` with every Rust dependency's source.
4. Wait for CI to pass, then create the `v<version>` release on GitHub, mark it as latest, upload the files listed in step 1 (DMG, `appcast.xml`, `.delta` updates) and the source archive, and take the release notes from the changelog. Keep the debug symbols from `target/dsym/`.

Details are in section 6 of the [Design and Engineering Guide](docs/DESIGN.en.md).
