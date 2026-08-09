# Extending the language guard to native platform code

Date: 2026-08-09
Status: approved, ready for implementation planning

Follows: `2026-08-09-english-only-strings-design.md`

## Problem

`test/language_test.dart` scans `lib/` for Polish string literals. Its own doc
comment names the gap it leaves:

> **The scan covers `lib/` only.** Native platform code under `ios/`, `android/`,
> `macos/`, `linux/` and `windows/` is out of scope and is not touched by this
> test at all.

That gap is not hypothetical. It is where the previous change's final review found
the two strings every earlier pass had missed — the same clipboard empty-state
sentence, in Swift and in Kotlin, in the very feature that change translated. The
guard built to stop the drift could not see the place the drift had actually
reached, because its scope was defined by the same incomplete sweep that missed
the strings.

## The measurement that shapes this design

The previous spec claimed native code "needs its own design" because "Swift and
Kotlin have different literal syntax and the Dart lexer regex would mis-parse
them." **That was theoretical caution, not a measurement, and measuring it
changed the answer.**

A raw whole-file text scan — no tokenizing, no literal parsing — was run over all
52 native source files (`.swift .kt .java .m .h .cc .cpp .xml .plist .storyboard
.xib` across the five platform directories), using the guard's existing
`diacritics` and `polishWords` patterns:

- diacritics: zero hits beyond the two known Polish strings
- wordlist: zero false positives, the same two files
- against `main`, where those two are already fixed: **completely clean**

So no lexer is needed. Not because a lexer would be wrong, but because it solves
a problem this codebase does not have.

## Design

### 1. Raw text, comments included — and the asymmetry is deliberate

Native files are scanned **in full**: code, comments, and XML text nodes alike.
The Dart half keeps skipping comments. That asymmetry is a decision, not an
oversight, and rests on two facts:

- **The Dart half skips comments for exactly one file.** `hotkey_binding.dart`
  carries a comment listing `ą/ć/ę/ł/ń/ó/ś/ź/ż` while explaining the AltGr
  reasoning. The whole tokenizer exists so that comment does not have to be
  deleted or the file allowlisted. No native file has an equivalent case —
  verified, not assumed.
- **`CLAUDE.md` requires English in comments too.** Where no legitimate exception
  exists, including comments is strictly more coverage for strictly less code.

There is also a category a literal-tokenizer could never have covered: `.plist`
and `.xml` have no string literals at all, only text nodes — and
`NSMicrophoneUsageDescription` lives in one. That string is rendered by the OS in
the microphone consent dialog, which makes it as user-facing as anything in the
Dart UI.

### 2. The file set, and the one exclusion that is load-bearing

Directories: `ios/`, `android/`, `macos/`, `linux/`, `windows/`.
Extensions: `.swift .kt .java .m .h .cc .cpp .xml .plist .storyboard .xib`.

Build scripts (`.gradle`, `.kts`, `.cmake`, `.pbxproj`) are out of scope — they
carry neither user-facing copy nor prose.

A path is skipped when any of its segments is `build`, `Pods`, `ephemeral`,
`.gradle`, `DerivedData` or **`.symlinks`**.

**`.symlinks` is the one that matters, and it is a Dart-specific trap.**
`ios/.symlinks/plugins/` and `android/.symlinks/` are symlinks into the pub
cache, and `Directory.listSync(recursive: true)` **follows links by default**
(`followLinks` defaults to `true`). Without this the scan walks into dozens of
third-party plugin sources — slow, and returning verdicts about code this
repository does not control. The implementation therefore does **both**: passes
`followLinks: false` *and* filters the segments. The first handles symlinks, the
second handles `build/` and `ephemeral/`, which are ordinary directories.

The exclusion list is measured rather than guessed. In a worktree where only
`flutter pub get` has run, the unfiltered find returns 60 files; eight of them
are under `ios/Flutter/ephemeral/` and `macos/Flutter/ephemeral/`
(`FlutterGeneratedPluginSwiftPackage`, `FlutterFramework`). Filtering leaves 52,
matching a clean checkout exactly.

### 3. One definition of each pattern

`diacritics` and `polishWords` are declared once and used by both the Dart scan
and the native scan. Two copies of a regex that must agree is the shape this
project already refuses elsewhere — `_matches()` in `queue_tab.dart` is one
definition precisely so the filter and its counts cannot disagree.

**This needs no refactoring.** Both patterns are already declared in `main()`
above the existing tests, so a third test in the same `main()` picks them up as
they stand. Hoisting them to top level, or extracting a helper, would be churn
that this design does not ask for.

### 4. No allowlist for native files

Verified: no native file needs an exemption today. An empty map plus a staleness
test iterating zero entries is dead code, so neither is written. The failure
message tells the reader what to do if a genuine case ever appears.

### 5. The non-empty assertion is the most important line in the new test

The native test asserts its file list is non-empty before scanning it.

Without that, a typo in a directory name or an extension produces a test that
**passes forever while checking nothing** — it scans an empty list and reports
success. The Dart half already carries this guard (`expect(sources, isNotEmpty)`)
where it is cheap insurance. Here it is load-bearing: the exclusion list is long
and easy to overshoot, and a rule that dropped one segment too many would
silently disable half the scan while staying green.

### 6. Failure message

`path:line  <the matching line, trimmed>`. A raw scan has no token to quote, so
it reports the line. Lines are truncated at 120 characters so a minified XML file
cannot turn one offence into a wall of output.

## Testing

- The two existing tests are unchanged in behaviour; only the file's doc comment
  is rewritten, since its current text states the native gap this change closes.
- New test: `no Polish in native platform sources`.
- New assertion: the native file list is non-empty (section 5).
- **Vacuity proof, both halves separately, on native files this time.** Inject a
  diacritic string into a `.swift` file and watch it fail; inject a
  diacritic-free Polish word (`Nowa`) into a `.kt` file and watch it fail. A test
  that has never been seen red is an assumption.
- **One extra proof specific to this change:** inject Polish into a `.plist` text
  node and watch it fail. That is the category with no string literals at all,
  and the one a tokenizer-based design would have missed — if it does not fire,
  the central claim of section 1 is wrong.
- Restore by copying from a scratchpad copy, never `git checkout -- <file>`.
  `CLAUDE.md` records that reverting to `HEAD` in a dirty tree once deleted the
  very fix under test.
- Gate: `flutter test` green; `flutter analyze` reporting nothing beyond the
  three pre-existing `info` issues that predate this branch.

## Risks and non-goals

- **The wordlist remains a heuristic.** Widening the scan does not make it a
  proof, and the doc comment must keep saying so.
- **A future `flutter create` may add native files** in directories not listed
  here. The non-empty assertion does not catch that — it only catches scanning
  *nothing*. This is a known limit, not a solved problem.
- **`feat/momentum-loop` still contains the two Polish native strings**, having
  branched before the fix. It gets both the fix and the stricter guard when it
  merges `main`, not before.
- Not in scope: any change to what the Dart half scans, and any per-language
  parsing.
