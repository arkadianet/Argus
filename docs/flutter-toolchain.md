# Flutter toolchain and dependency updates

CI pins Flutter **3.41.2** (Dart **3.11.0**) in `FLUTTER_VERSION` in
`.github/workflows/ci.yml`. Update that value deliberately and run
`flutter pub get --enforce-lockfile`, `flutter analyze` and `flutter test`
on the proposed SDK before merging. The application tracks `app/pubspec.lock`;
CI enforces it so a fresh checkout uses the same dependency versions as local tests.
For a deliberate dependency update, resolve only the intended packages, review
the lockfile diff, and run the Flutter checks plus affected platform builds.

## September 2026 native hook failure

The existing local resolution uses `objective_c 9.5.0` and `code_assets 1.2.1`.
The dependency path is `share_plus 11.1.0` → `share_plus_platform_interface 6.1.0`
→ `path_provider 2.1.6` → `path_provider_foundation 2.6.0` → `objective_c`.
The previously ignored lockfile allowed CI to resolve newer packages.

The published `objective_c 9.6.1` build hook imports `Architecture` from
`package:code_assets/code_assets.dart` and references `Architecture.arm64e`.
Published `code_assets 2.0.0` does not define that member. This is a package
API mismatch, not evidence that Flutter removed an SDK member. Pinning Flutter
alone cannot fix it; retaining and enforcing the working dependency resolution
is also necessary.

Checked the pub.dev package API and published archives on 2026-09-15:
[objective_c](https://pub.dev/packages/objective_c/versions/9.6.1) 9.6.1,
[code_assets](https://pub.dev/packages/code_assets/versions/2.0.0) 2.0.0 and
[path_provider_foundation](https://pub.dev/packages/path_provider_foundation/versions/2.6.0)
2.6.0 are the latest published releases. No newer published fix is available.
`share_plus` 13.3.0 still depends on a platform interface that uses
`path_provider`, so upgrading it does not remove this chain.

Wait for a compatible upstream release, then update the relevant transitive
packages and verify hooks on the proposed SDK and supported platform builds.
Do not broaden this into a `share_plus` upgrade: the
[existing dependency assessment](superpowers/specs/2026-09-02-argus-future-work.md)
records that `share_plus` 13.3.0 fails to compile Android sources in this Gradle
setup, which needs separate Android work and validation. (FRB has since been
upgraded on its own; see below.)

Verified the CI-only change with an unmodified writable copy of Flutter 3.41.2:
`cd app && flutter pub get --enforce-lockfile` passed, `flutter analyze` reported
no issues, and `flutter test` passed 884 tests with one skipped. SDK, pub cache,
temporary files and logs were kept in this worktree because the installed SDK
and user cache are read-only in the sandbox.

## October 2026 flutter_rust_bridge 2.13.0

Requested together with updating every Rust crate and the Rust toolchain
(now 1.99.0 in `rust/rust-toolchain.toml` and CI). FRB moved from 2.11.1 to
2.13.0, the newest stable release on 2026-10-06; 2.14.0 is still in beta.
Three pins must always name the same version:

- the Rust crate: `flutter_rust_bridge = "=2.13.0"` in `rust/Cargo.toml` and
  `rust/crates/wallet-ffi/Cargo.toml`;
- the Dart package: `flutter_rust_bridge: 2.13.0` in `app/pubspec.yaml`
  (resolved with `flutter pub upgrade flutter_rust_bridge`, which changed only
  that package in `app/pubspec.lock`);
- the codegen CI installs (`cargo install flutter_rust_bridge_codegen
  --version 2.13.0 --locked`). cargo-expand stays at 1.0.110: FRB only needs
  some version installed.

Bindings were regenerated from the repository root with the 2.13.0 codegen.
The API did not change, so `rustContentHash` is unchanged; the generated code
differs in version strings, fully qualified `Ok` in the Rust wire functions,
extra lint allowances and a `wasmBindgenName` field in the Dart loader
config. Rust 1.99 also renames a derive helper listed in a comment in
`app/lib/bridge/api.dart` (`assert_fields_are_eq`), so regenerating with an
older toolchain produces a diff.

The tracked `jniLibs` were built with FRB 2.11.1 and are now stale: rebuild
them with `scripts/build_android.sh` before running the app, and let
`scripts/release_check.sh libs` confirm them before a release. The init-time
content hash check would not catch the mismatch on its own.
