# Augustyniak AI Rebrand Plan

## Outcome

Ship one coherent product identity across Flutter, Android, iOS, macOS, Linux,
Windows, documentation, tests, generated artifacts, and distribution metadata.
The installed application is named **Augustyniak AI**. No legacy brand token,
package name, reverse-DNS identifier, executable name, window title, permission
copy, test fixture, or generated asset reference remains in the repository.

This plan deliberately separates the smallest compiling rename from visual
polish. Each phase ends in a runnable state.

## Canonical naming contract

| Surface | Canonical value |
| --- | --- |
| Product and display name | `Augustyniak AI` |
| UI eyebrow | `AUGUSTYNIAK AI` |
| Dart package | `augustyniak_ai` |
| Root widget | `AugustyniakAiApp` |
| Executable / binary stem | `augustyniak_ai` |
| Application identifier | `ai.augustyniak.app` |
| Test application identifier | `ai.augustyniak.app.RunnerTests` |
| Android Kotlin package | `ai.augustyniak.app` |
| Session and temporary-file prefix | `augustyniak-ai` |
| Publisher / company label | `Augustyniak AI` |
| Primary web identity | `augustyniak.ai` |

Do not introduce shorter surname variants. `Augustyniak` is the brand owner and
must remain intact wherever the identity is user-visible.

## Gate 0: release identity and user data

Before changing any reverse-DNS identifier, confirm that no build using the
legacy identifier has been published in an application store.

- **Not published:** use `ai.augustyniak.app` everywhere. This is the assumed
  route for this branch.
- **Already published:** preserve the store identifier to retain upgrade
  continuity, or explicitly ship a new listing and design a one-time data
  migration. Do not silently choose between these outcomes.

Changing the identifier can change the application container on Android and
Apple platforms. Before release, install the old and new builds on each target
and prove that existing captures, `recordings.json`, `settings.json`,
`projects.json`, revisions, logs, and credentials are either preserved or
migrated. Source files must never be deleted as part of migration.

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

1. Rename the Dart package in `pubspec.yaml` to `augustyniak_ai`.
2. Rewrite all `package:` imports in `lib/` and `test/`.
3. Rename the root application widget to `AugustyniakAiApp`.
4. Replace the Material application title and every visible eyebrow with the
   canonical display name.
5. Replace user-visible window titles and microphone permission descriptions.
6. Run formatting, static analysis, and the complete test suite.

Exit condition: the Flutter application compiles and tests pass while displaying
the new name. Native identifiers may still be handled in the next isolated
commit, but no user-visible legacy name may remain.

## Phase 2: native platform identity

### Android

- Change `namespace` and `applicationId` to `ai.augustyniak.app`.
- Move `MainActivity.kt` to `android/app/src/main/kotlin/ai/augustyniak/app/` and
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

Where a generated name may already exist on a user's machine, support reading
the prior value while writing only the canonical value. Compatibility code must
not expose the prior brand in the interface or create new files under it.

## Phase 4: documentation and repository metadata

- Rewrite `README.md`, `CLAUDE.md`, code comments, installation commands, signing
  examples, and architectural descriptions.
- Rename the repository and primary checkout only after code-level verification;
  update the Git remote and any external scripts in the same operation.
- Search external release scripts, store listings, signing configuration,
  screenshots, package registries, website metadata, and social profiles. These
  are outside this worktree and require a separate deployment checklist.

## Phase 5: visual identity

The current waveform icon is mechanically reusable but conflicts with the
multimodal product: captures can be audio, text, image, or video. Replace it with
an identity that can represent `Augustyniak AI` without encoding only audio.

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

- Repository-wide, case-insensitive scans return zero matches for the legacy
  product word, compound display name, snake-case package name, and reverse-DNS
  identifier. Include hidden files; exclude only `.git/` and build outputs.
- No tracked path contains a legacy brand token.
- `git diff --check` passes.
- `dart format --output=none --set-exit-if-changed lib test` passes.
- `flutter analyze` passes.
- `flutter test` passes.

### Artifact checks

- Android manifest and APK report `Augustyniak AI` and `ai.augustyniak.app`.
- iOS and macOS built plists report the expected product and bundle identifiers.
- Linux desktop metadata and GTK runtime title match the contract.
- Windows executable properties and window title match the contract.
- Launching via the global shortcut focuses the renamed window.
- Zellij sessions use the new prefix and remain within their length limit.

### Data-safety checks

- Make a capture with the pre-rebrand build, then install and launch the
  rebranded build on every supported platform.
- Confirm source bytes, index rows, projects, settings, revisions, and logs.
- Simulate a failed migration and prove the original files remain untouched.
- Back up the application data directory before any destructive migration test.

## Commit sequence

1. `refactor: rename Flutter product and Dart package`
2. `build: align native application identities`
3. `refactor: rename runtime prefixes and fixtures`
4. `docs: adopt Augustyniak AI identity`
5. `design: replace application icon and store artwork`
6. `test: add rebrand and data-migration verification`

Do not squash these until every platform artifact has been checked; the sequence
provides useful rollback points if a native runner breaks.

## Definition of done

The rebrand is complete only when a clean clone can analyze, test, and build the
supported artifacts; installed applications display `Augustyniak AI`; all
identifiers match the canonical contract; existing user data is demonstrably
safe; and exhaustive scans find no legacy identity in tracked content or paths.
