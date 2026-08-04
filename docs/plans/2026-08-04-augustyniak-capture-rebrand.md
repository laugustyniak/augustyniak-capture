# Augustyniak Capture Rebrand Plan

## Outcome

Ship one coherent product identity across Flutter, Android, iOS, macOS, Linux,
Windows, documentation, tests, generated artifacts, and distribution metadata.
The installed application is named **Augustyniak Capture** and is published by
**Augustyniak AI**. Under the assumed undistributed route, no legacy brand
token, package name, reverse-DNS identifier, executable name, window title,
permission copy, test fixture, or generated asset reference remains in the
repository.

The plan deliberately separates the smallest compiling rename from visual
polish. Each phase ends in a runnable state.

## Canonical naming contract

| Surface | Canonical value |
| --- | --- |
| Product and display name | `Augustyniak Capture` |
| UI eyebrow | `AUGUSTYNIAK CAPTURE` |
| Dart package | `augustyniak_capture` |
| Root widget | `AugustyniakCaptureApp` |
| Executable / binary stem | `augustyniak_capture` |
| Application identifier | `ai.augustyniak.capture` |
| Test application identifier | `ai.augustyniak.capture.RunnerTests` |
| Android Kotlin package | `ai.augustyniak.capture` |
| Session and temporary-file prefix | `augustyniak-capture` |
| Publisher / company label | `Augustyniak AI` |
| Product web identity | `augustyniak.ai/capture` |

Do not introduce shorter surname variants. `Augustyniak` is the brand owner and
must remain intact wherever the identity is user-visible.

## Gate 0: release identity and user data

Before changing any reverse-DNS identifier, confirm that no build using the
legacy identifier has been published in an application store or distributed to
users whose local data must survive the rename.

- **Not published or distributed:** use `ai.augustyniak.capture` everywhere.
  This is the assumed route for this branch; there is no compatibility layer and
  repository scans can require zero legacy identity tokens.
- **Already published:** preserve the store identifier to retain upgrade
  continuity, or explicitly ship a new listing with a user-driven export/import
  migration. A new Android application ID or Apple bundle ID has a different
  sandbox and cannot directly read the previous application's private data.
  Do not silently choose between these outcomes.

If Gate 0 finds distributed builds, define and test the export/import path before
changing identifiers. It must cover captures, `recordings.json`, `settings.json`,
`projects.json`, revisions, and logs. Credentials require a separate decision:
do not export plaintext secrets by default. Source files must never be deleted
as part of migration.

## Baseline inventory

The initial audit at commit `61b5b17` found:

- 313 legacy-name occurrences across 65 tracked files;
- 214 Dart package-name occurrences, predominantly test imports;
- 20 reverse-DNS identifier occurrences;
- native application names in all five checked-in desktop/mobile runners;
- an Android Kotlin directory whose path encodes the old namespace;
- runtime prefixes in Zellij sessions, temporary video-audio directories, and
  test fixtures;
- a waveform-based application icon that contains no text but still presents
  the product as audio-only.

The inventory must be regenerated after every phase; do not treat these counts
as a permanent allowlist.

## Phase 1: smallest compiling product rename

1. Rename the Dart package in `pubspec.yaml` to `augustyniak_capture`.
2. Rewrite all `package:` imports in `lib/` and `test/`.
3. Rename the root application widget to `AugustyniakCaptureApp`.
4. Replace the Material application title and every visible eyebrow with the
   canonical display name.
5. Replace user-visible window titles and microphone permission descriptions.
6. Run formatting, static analysis, and the complete test suite.

Exit condition: the Flutter application compiles and tests pass while displaying
the new name. Native identifiers may still be handled in the next isolated
commit, but no user-visible legacy name may remain.

## Phase 2: native platform identity

### Android

- Change `namespace` and `applicationId` to `ai.augustyniak.capture`.
- Move `MainActivity.kt` to
  `android/app/src/main/kotlin/ai/augustyniak/capture/` and
  update its package declaration.
- Update the manifest label.
- Rename the signing-keystore example and its documentation without touching a
  real, untracked keystore.

### iOS and macOS

- Change product names, display names, executable references, bundle identifiers,
  test bundle identifiers, Xcode scheme buildable names, test hosts, permission
  copy, and copyright metadata.
- Preserve the hand-maintained iOS plist keys and the macOS entitlement choices.
- Do not regenerate either Xcode project wholesale.

### Linux

- Change the CMake binary name, GTK application identifier, window title, and
  icon lookup name.

### Windows

- Change the CMake project and binary names, runner window title, company name,
  file description, internal name, original filename, product name, and
  copyright metadata.

Exit condition: native configuration contains one naming contract and each
available platform produces an artifact with the expected installed name.

## Phase 3: runtime-generated names and compatibility

Replace brand-bearing operational prefixes in:

- Zellij session naming and its length calculation;
- temporary directories used by media processing;
- project-name hints and examples;
- system-window matching expressions;
- test fixtures, expected session names, temporary directories, and sample
  project identifiers.

Under the assumed undistributed route, rename these values without a fallback.
If Gate 0 instead requires compatibility, isolate every necessary legacy literal
in one migration module, document the exception to the zero-match rule, and test
that it reads prior values while writing only canonical ones. Compatibility code
must not expose the prior brand in the interface or create new files under it.

## Phase 4: documentation and repository metadata

- Rewrite `README.md`, `CLAUDE.md`, code comments, installation commands, signing
  examples, and architectural descriptions.
- After code-level verification and **before merging the implementation PR**,
  rename the GitHub repository to `augustyniak-capture`, rename the primary
  checkout, and update Git remotes plus external scripts in the same operation.
- Search external release scripts, store listings, signing configuration,
  screenshots, package registries, website metadata, and social profiles. These
  are outside this worktree and require a separate deployment checklist.

## Phase 5: visual identity

The current waveform icon is mechanically reusable but conflicts with the
multimodal product: captures can be audio, text, image, or video. Replace it with
an identity that can represent `Augustyniak Capture` without encoding only
audio.

Deliverables:

- one approved 1024 px source icon;
- regenerated Android, iOS, macOS, Linux, and Windows icon sets;
- dark- and light-background checks;
- legibility checks at 16, 32, 64, and 128 px;
- updated screenshots and store artwork.

Keep visual redesign in a separate commit from the mechanical rename so failures
remain easy to isolate.

## Verification matrix

### Repository invariants

- Under the assumed undistributed route, repository-wide, case-insensitive scans
  return zero matches for the legacy product word, compound display name,
  snake-case package name, and reverse-DNS identifier. Include hidden files;
  exclude only `.git/` and build outputs. If Gate 0 requires migration, the sole
  reviewed migration module is the only permitted exception.
- No tracked path contains a legacy brand token; the optional migration-module
  exception applies to file contents only.
- `git diff --check` passes.
- `dart format --output=none --set-exit-if-changed lib test` passes.
- `flutter analyze` passes.
- `flutter test` passes.

### Artifact checks

- Android manifest and APK report `Augustyniak Capture` and
  `ai.augustyniak.capture`.
- iOS and macOS built plists report the expected product and bundle identifiers.
- Linux desktop metadata and GTK runtime title match the contract.
- Windows executable properties and window title match the contract.
- Launching via the global shortcut focuses the renamed window.
- Zellij sessions use the new prefix and remain within their length limit.

### Data-safety checks

- If Gate 0 finds distributed builds, export a capture set from the pre-rebrand
  build and import it into the rebranded build on every supported platform.
- Confirm source bytes, index rows, projects, settings, revisions, and logs;
  confirm separately that credentials were not exported implicitly.
- Simulate a failed import and prove the original files remain untouched.
- Back up the application data directory before any destructive migration test.

## Commit sequence

1. `refactor: rename Flutter product and Dart package`
2. `build: align native application identities`
3. `refactor: rename runtime prefixes and fixtures`
4. `docs: adopt Augustyniak Capture product identity`
5. `design: replace application icon and store artwork`
6. `test: add rebrand and data-migration verification`

Do not squash these until every platform artifact has been checked; the sequence
provides useful rollback points if a native runner breaks.

## Definition of done

The rebrand is complete only when a clean clone can analyze, test, and build the
supported artifacts; installed applications display `Augustyniak Capture`; all
identifiers match the canonical contract; the GitHub repository has been renamed
to `augustyniak-capture`; existing user data is demonstrably safe; and exhaustive
scans find no unauthorized legacy identity in tracked content or paths.
