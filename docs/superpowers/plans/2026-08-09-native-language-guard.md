# Native language guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend `test/language_test.dart` so it also catches Polish in native platform sources, closing the gap where the previous change's two missed strings actually lived.

**Architecture:** One new test in the existing file. Native files are scanned as raw text — no tokenizing, no comment skipping — reusing the `diacritics` and `polishWords` patterns already declared in `main()`. The Dart scan is untouched; only the file's doc comment is rewritten, because its current text advertises the very gap this closes.

**Tech Stack:** Dart, `flutter_test`, `dart:io`. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-08-09-native-language-guard-design.md`

## Global Constraints

- **No new dependencies.** `pubspec.yaml` must not change.
- **Do not change what the `lib/` scan does.** Its tokenizer, its allowlist and both existing tests keep their current behaviour. Only the file-level doc comment is rewritten.
- **Do not hoist or extract the existing regexes.** `diacritics` and `polishWords` are already declared in `main()` above the tests; a third test in the same `main()` picks them up as they stand. Refactoring them to top level or into a helper is churn this design does not ask for.
- **No allowlist for native files.** No native file needs an exemption today; an empty map plus a staleness test over zero entries is dead code. The failure message covers the future case.
- **`followLinks: false` is mandatory** on the native directory walk, *in addition to* the skipped-segment filter. `Directory.listSync(recursive: true)` follows symlinks by default, and `ios/.symlinks/` points into the pub cache.
- **Gate:** `flutter test` fully green, and `flutter analyze` reporting no issue beyond the three pre-existing `info` issues (`compact_queue_header.dart:96`, `qr_sync_sheet.dart:238`, `qr_sync_sheet.dart:239`). `flutter analyze` exits 1 on those alone — a non-zero exit is not by itself a failure. Baseline: 675 tests passing.
- **Commit messages:** plain subject line, body only when it explains something the diff cannot. No tool attribution, no co-author trailers, no emoji.

---

### Task 1: The native scan

**Files:**
- Modify: `test/language_test.dart` — rewrite the doc comment's third paragraph, add one test

**Interfaces:**
- Consumes: `diacritics` and `polishWords`, both already declared inside `main()` in this file.
- Produces: nothing other code reads.

- [ ] **Step 1: Rewrite the doc comment's native paragraph**

Replace this paragraph (currently the third in the file's `///` block):

```dart
/// **The scan covers `lib/` only.** Native platform code under `ios/`,
/// `android/`, `macos/`, `linux/` and `windows/` is out of scope and is not
/// touched by this test at all — it has its own string-literal syntax that
/// this Dart-token regex cannot parse, and `flutter test` never compiles it
/// in the first place. Polish there has to be found by hand.
```

with:

```dart
/// **Two scans, deliberately unequal.** The `lib/` scan reads string literals
/// and skips comments, because `hotkey_binding.dart` legitimately lists
/// `ą/ć/ę/ł/ń/ó/ś/ź/ż` while explaining AltGr. The native scan reads whole
/// files, comments included: no native file has an equivalent case, `CLAUDE.md`
/// asks for English in comments too, and `.plist`/`.xml` carry user-facing text
/// in nodes rather than in literals — `NSMicrophoneUsageDescription` is what
/// the OS shows in the microphone consent dialog. A raw scan of all 52 native
/// sources produced zero false positives, so the Dart tokenizer would buy
/// nothing there and would miss the XML entirely.
```

Leave the first two paragraphs — the `CLAUDE.md` quote and the "tripwire, not a proof" paragraph — exactly as they are. The heuristic disclaimer still holds and must not be softened.

- [ ] **Step 2: Add the native test**

Append this test inside `main()`, after the two existing tests:

```dart
  test('no Polish in native platform sources', () {
    const List<String> platformDirs = <String>[
      'ios',
      'android',
      'macos',
      'linux',
      'windows',
    ];
    const List<String> extensions = <String>[
      '.swift',
      '.kt',
      '.java',
      '.m',
      '.h',
      '.cc',
      '.cpp',
      '.xml',
      '.plist',
      '.storyboard',
      '.xib',
    ];
    // `build`/`ephemeral` are ordinary directories; `.symlinks` is not — it
    // points into the pub cache, and `listSync` follows links by default, so
    // the walk below also passes `followLinks: false`. Both are needed: the
    // flag handles the symlink, the filter handles the directories.
    const Set<String> skippedSegments = <String>{
      'build',
      'Pods',
      'ephemeral',
      '.gradle',
      '.symlinks',
      'DerivedData',
    };

    final List<File> sources = <File>[];
    for (final String dir in platformDirs) {
      final Directory root = Directory(dir);
      if (!root.existsSync()) continue;
      for (final FileSystemEntity entity
          in root.listSync(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final String relative = entity.path.replaceAll(r'\', '/');
        if (relative.split('/').any(skippedSegments.contains)) continue;
        if (!extensions.any(relative.endsWith)) continue;
        sources.add(entity);
      }
    }

    // The most important assertion in this test. A typo in a directory name or
    // an extension, or a skip rule one segment too broad, otherwise yields a
    // test that passes forever while scanning nothing.
    expect(
      sources,
      isNotEmpty,
      reason: 'the native scan matched no files at all — it is checking '
          'nothing. Run from the repository root, and check platformDirs, '
          'extensions and skippedSegments before trusting a green run.',
    );

    final List<String> offences = <String>[];
    for (final File file in sources) {
      final String relative = file.path.replaceAll(r'\', '/');
      final List<String> lines = file.readAsStringSync().split('\n');
      for (int i = 0; i < lines.length; i++) {
        final String line = lines[i];
        if (!diacritics.hasMatch(line) && !polishWords.hasMatch(line)) {
          continue;
        }
        final String trimmed = line.trim();
        final String shown =
            trimmed.length > 120 ? '${trimmed.substring(0, 120)}…' : trimmed;
        offences.add('$relative:${i + 1}  $shown');
      }
    }

    expect(
      offences,
      isEmpty,
      reason: 'Polish found in native platform sources. Unlike the lib/ scan '
          'this one reads whole files, comments included — CLAUDE.md asks for '
          'English there too. Translate it. If a native file ever has a '
          'genuine reason to hold Polish, add an allowlist here rather than '
          'narrowing the scan:\n${offences.join('\n')}',
    );
  });
```

Note on `readAsStringSync`: all 52 native sources are us-ascii or utf-8 (verified), so this is safe. A future binary `.plist` would throw a `FileSystemException` rather than being skipped — loud, which is the right failure for a file the scan cannot read.

- [ ] **Step 3: Run the file**

Run: `flutter test test/language_test.dart`
Expected: PASS, 3 tests. Native sources are already clean on this branch — the previous change translated the two Swift/Kotlin strings.

If it fails, read the offences. Either a native Polish string survived (translate it and say so in your report — it means the earlier sweep was still incomplete) or the wordlist false-positives on English (narrow the offending word; do **not** add an allowlist to silence it).

- [ ] **Step 4: Prove the scan is not vacuous — three injections, one per category**

A test that has never been seen red is an assumption. Copy each file to the scratchpad before editing and restore from that copy — **never `git checkout -- <file>`**, which reverts to `HEAD` and takes every other uncommitted change in the file with it. Use `/private/tmp/claude-501/-Users-laugustyniak-github-apps-augustyniak-capture/dc632511-4a54-4ed4-bc7d-9a045ab224af/scratchpad`. Note `cp` is aliased interactively on this machine — use `command cp -f` and verify with `diff -q`.

**4a — diacritic half, in Swift.** In `ios/CaptureKeyboard/CaptureKeyboardViewController.swift`, change the empty-state string to `"Brak skopiowanych elementów"`.

Run: `flutter test test/language_test.dart`
Expected: FAIL, naming `ios/CaptureKeyboard/CaptureKeyboardViewController.swift:<line>` and showing the line.

**4b — wordlist half, in Kotlin.** Restore 4a, then in `android/app/src/main/kotlin/ai/augustyniak/capture/CaptureInputMethodService.kt` change the empty-state string to `"Nowa"` (no diacritic anywhere).

Run: `flutter test test/language_test.dart`
Expected: FAIL, naming the Kotlin file. If this passes, the wordlist branch is not reaching native files and the test is half of what it claims.

**4c — XML text node, in a plist.** Restore 4b, then in `ios/Runner/Info.plist` change the `NSMicrophoneUsageDescription` value to `Dostęp do mikrofonu`.

Run: `flutter test test/language_test.dart`
Expected: FAIL, naming `ios/Runner/Info.plist`. This is the category with no string literals at all — the one a tokenizer-based design would have missed. If it does not fire, the central claim of the spec is wrong; stop and report rather than working around it.

Restore, then confirm green:

Run: `flutter test test/language_test.dart`
Expected: PASS, 3 tests.

- [ ] **Step 5: Prove the non-empty assertion is not vacuous**

The spec calls this the most important line in the test, so verify it fires. Temporarily change `platformDirs` to a single bogus entry:

```dart
    const List<String> platformDirs = <String>['iosX'];
```

Run: `flutter test test/language_test.dart`
Expected: FAIL on the `isNotEmpty` assertion with the "matched no files at all" reason — **not** a pass. A pass here means a mis-scoped scan would ship green.

Restore the real list and re-run:

Run: `flutter test test/language_test.dart`
Expected: PASS, 3 tests.

- [ ] **Step 6: Confirm the walk does not follow symlinks into the pub cache**

`ios/.symlinks/` may not exist in this worktree, so the filter alone would look sufficient. Verify the flag is actually set rather than inferring it from a green run:

Run: `grep -n "followLinks" test/language_test.dart`
Expected: one hit, `followLinks: false`.

Also confirm the file count is the expected 52 rather than 60 — the difference is the eight `ephemeral/` Swift package files that `flutter pub get` creates (`FlutterGeneratedPluginSwiftPackage`, `FlutterFramework`, under `ios/Flutter/ephemeral/` and `macos/Flutter/ephemeral/`).

Do **not** use `print` for this: `avoid_print` is enabled in `analysis_options.yaml`. Temporarily tighten the existing assertion instead:

```dart
    expect(sources, hasLength(52), reason: 'temporary count check');
```

Run: `flutter test test/language_test.dart`
Expected: PASS. If it reports a different length, the skip filter is wrong — 60 means the `ephemeral` segment is not being skipped, and anything under 52 means a rule is too broad.

Then remove that line. It is a check, not a permanent assertion: pinning the count would make every legitimately added native file a test failure.

- [ ] **Step 7: Full gate**

Run: `flutter test`
Expected: 676 tests passing (675 baseline + 1 new).

Run: `flutter analyze`
Expected: exactly the three pre-existing `info` issues, nothing new. A non-zero exit code on those three alone is not a failure.

- [ ] **Step 8: Confirm the tree is clean of the temporary edits**

Run: `git status --short`
Expected: only `test/language_test.dart` modified. If any native file or `Info.plist` still shows as modified, a restore in Step 4 did not land.

- [ ] **Step 9: Commit**

```bash
git add test/language_test.dart
git commit -m "Extend the language guard to native platform sources

The gap this closes is where the drift actually reached: the final review of
the English-only change found the same clipboard empty-state string in Swift
and Kotlin, in the feature that change had just translated.

Native files are scanned as raw text rather than through the Dart tokenizer.
A raw scan of all 52 of them produces zero false positives, so the tokenizer
would buy nothing — and it would miss .plist and .xml entirely, which carry
user-facing text in nodes rather than literals. NSMicrophoneUsageDescription
is the one the OS shows in the consent dialog.

Comments are in scope here and not in lib/, because one Dart file
legitimately lists Polish letters while explaining AltGr and no native file
has an equivalent case."
```

---

## After the plan

Two limits this deliberately leaves standing, recorded so they are not mistaken for oversights:

- **The wordlist stays a heuristic.** Scanning more files does not make it a proof, and the doc comment still says so.
- **A future `flutter create` may add native files outside the five listed directories.** The non-empty assertion does not catch that — it only catches scanning *nothing*. Known limit, not a solved problem.
