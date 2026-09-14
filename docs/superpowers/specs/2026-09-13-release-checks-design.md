# Release checks: what they catch, and why they exist

Date: 2026-09-13
Status: implemented as `scripts/release_check.sh`, exercised against alpha.53.

Three things have to be true of a release that nothing verified. Each was
missed by hand at least once, and two of the three misses would have shipped.

## What went wrong

**alpha.52 — the tracked native libraries were stale.** `jniLibs/*.so` are
committed and are what a release APK links against. They are rebuilt at release
time (`935a4ab`, `9f8534b`, `56070c6`), and PRs #116 and #117 had merged without
one. Caught only by looking.

**alpha.53 — the split APKs carried the wrong versionCode.** Flutter adds an ABI
offset (arm64 +2000, x86_64 +4000) to the base code, but only when *it* performs
the split. `flutter build apk --release --split-per-abi` followed by a plain
`flutter build apk --release` re-runs Gradle, which splits regardless of the
flag, and overwrites the correctly-offset APKs with ones carrying the bare base
code — same filenames, same minute. Every alpha.52 arm64 user sits on
versionCode 6053, so shipping 4054 would have been a downgrade and Android would
have refused the update with no obvious cause.

The offsets are not in `build.gradle.kts` — that file is only
`versionCode = flutter.versionCode`. Looking there for them finds nothing.

## Why the existing guard was not enough

flutter_rust_bridge writes a `rustContentHash` into `frb_generated.dart` and
checks it at init. When the libraries go stale it normally changes too, so the
app dies on launch: obvious, and caught on first run.

**It does not always change.** The mix-key change in #118 moved two functions
from `String` to `Vec<u8>` and left the hash at `-274834265`. An APK built
against the old libraries would have started normally and failed only when a
background mix first called one of them, decoding a byte vector as UTF-8.

|  | detected by | when it shows |
|---|---|---|
| hash moves | init check | first launch, loudly |
| hash does not move | nothing | first call to the changed function |

So the check cannot compare hashes. It has to compare the libraries.

## Comparing libraries needs a reproducible build

The first attempt at this failed: rebuilding from unchanged source produced
different bytes, because the absolute build path is baked in and the earlier
build had run in a worktree. `.text` differed too, so it was not only a
`.rodata` problem — the shifted string table moves code.

The exported symbol table did match, and would have caught #118 since that
changed the ABI. But a symbol comparison cannot see a body-only edit: same
symbols, different behaviour, silent pass.

`--remap-path-prefix` fixes it properly. With the repo root and `~/.cargo`
remapped, two builds of identical source at deliberately different path lengths
are **byte-identical**, verified. `build_android.sh` now sets this, so a plain
`cmp` is both sound and strictly stronger than the symbol fallback.

The libraries were rebuilt once under the new flags to establish the baseline.
They are functionally identical to what alpha.53 shipped; only the embedded
paths differ.

## The checks

`scripts/release_check.sh {version|libs|apks <dir>|all <dir>}`

- **version** — `build_info.dart` and `pubspec.yaml` agree on name and number.
- **libs** — rebuilds into a scratch directory via `OUT_DIR` and compares byte
  for byte against the tracked libraries.
- **apks** — every APK carries the expected versionCode for its ABI, the
  expected versionName, only the ABI it claims, and the same signing
  certificate as the others. It prints the certificate digest so it can be
  compared against the previous release before publishing.

## Two properties that matter more than the checks themselves

**Assert on positive evidence, never on the absence of a difference.** Both
early attempts at the reproducibility experiment produced a false pass: one
compared two empty strings and reported "identical", the other hashed a file
mid-copy and got the empty-file digest. `libs` fails explicitly when a rebuild
produces no artifact, rather than letting a missing file look like a match.

**Assert against expected values, not plausibility.** The broken alpha.53 build
passed every check of the form "the APKs exist and are signed". Only comparing
each versionCode against a computed expectation caught it.

## Where this runs, and what it does not solve

A release preflight, not CI. Both misses happened at release time rather than at
merge, `apks` can only run where signed APKs exist, and adding an NDK
cross-compile to every PR is a real cost. If libraries start going stale between
releases, moving `libs` alone into CI is the obvious next step.

This replaces "remember to check three things" with "remember to run one
script", which is an improvement and not automation. Folding it into a release
script that also drives the build would close that gap.
