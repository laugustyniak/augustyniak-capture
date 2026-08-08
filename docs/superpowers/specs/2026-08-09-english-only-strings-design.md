# English-only UI strings, and the layering fix that makes i18n cheap later

Date: 2026-08-09
Status: approved, ready for implementation planning

## Problem

Two features shipped with Polish user-facing strings while the rest of the app is
English. `CLAUDE.md` already states the rule — "user-facing strings in code are
English (they were Polish until the design pass — do not reintroduce Polish)" —
but nothing enforces it, so the drift was invisible until someone read the
screens.

The Polish is not scattered. It sits in exactly two files:

| File | Polish strings | Layer |
| --- | --- | --- |
| `lib/features/gamification/domain/milestone.dart` | ~20 | `domain/` |
| `lib/features/clipboard/presentation/clipboard_history_sheet.dart` | 11 | `presentation/` |

The second file is a plain translation. The first is not: those sentences are
built inside `domain/`, which is why that file imports
`package:flutter/material.dart` (for `IconData` and `Color`). That import is the
actual defect — it is the same layering mistake `ClipboardSink` and `AlarmPlayer`
were designed to avoid, and it is what would make a future i18n pass expensive.

## Non-goals

This change does **not** add i18n infrastructure. No `flutter_localizations`, no
`intl`, no ARB files, no `l10n.yaml`. A full `gen-l10n` migration was costed at
roughly 1.5–2 days and rejected for now because there is no second-language
audience; the decision was "English-only hygiene now, `gen-l10n` later if an
audience appears". Nothing here makes that later pass harder — it visits every
file regardless.

Explicitly out of scope, and deliberately so:

- **Moving the milestone hex colours into `ConsolePalette`.** `CLAUDE.md` says
  every raw hex belongs there, and these eight do not. That is a real debt, but
  mixing a palette migration into a string change would make the diff unreadable
  and would put a colour regression and a translation regression in one commit.
- **Migrating existing on-disk data.** See "Collection names" below.
- **Rewording anything.** Translations are 1:1. Preserving the exact English
  wording elsewhere is what keeps the 367 text assertions across the test suite
  from being disturbed; the same discipline applies here.

## Design

### 1. `milestone.dart` — domain carries the fact, presentation carries the words

`Milestone` keeps `id`, `type`, `count`. It drops `title`, `description`, `icon`,
`color`, and with them the `package:flutter/material.dart` import: the file
becomes pure Dart.

This is safe because of what the consumers actually read.
`gamification_controller.dart` uses only `.id`. The four dropped fields are read
by exactly one widget, `celebration_overlay.dart`, plus two assertions in
`test/gamification_test.dart`. A domain class was carrying four fields for a
single widget.

`isMilestoneCount` (which counts are thresholds) and `check` (whether a threshold
is already unlocked) stay in the domain. Those are rules. The tier cosmetics —
which icon and colour a 50 gets versus a 300 — are not.

New file `lib/features/gamification/presentation/milestone_copy.dart` exposes:

```dart
({String title, String description, IconData icon, Color color})
    milestoneCopyFor(Milestone milestone)
```

It reproduces the existing threshold cascade (1 / 10 / 20 / 50 / 100 / 200 / 300,
then every further 100) with the same icons and the same colours, and English
text. `celebration_overlay.dart` calls it once per shown milestone and reads the
record.

**Why a function returning a record rather than fields on a `MilestoneCopy`
class:** there is one call site and no state. A class would add a name to learn
for no reduction in anything.

### 2. `clipboard_history_sheet.dart` — translation, with one exception

Eleven UI strings become English, 1:1.

**Collection names are the exception.** `'Ulubione'`, `'Kod'`, `'Prompty'` and
`'Ważne'` are default *suggestions* for naming a clipboard collection; a chosen
suggestion becomes data written to disk. `CLAUDE.md` already rules on this:
"Strings already stored on disk (a provider profile the user named) keep whatever
they were saved as; only code literals were translated."

So: the suggestion list in the source is translated, and **no migration touches
existing collections**. A collection already named `Ważne` stays `Ważne`. The
consequence is a mixed list for the current user — the four English suggestions
alongside their existing Polish collections — and that is the correct outcome
rather than a defect. Renaming a user's data to match a code change is the class
of action this repo refuses everywhere else.

### 3. `test/language_test.dart` — the guard

Written in the idiom `theme_test.dart` already established:
`Directory('lib').listSync(recursive: true)`, read each `.dart` source, scan with
a `RegExp`.

It strips comments first, then fails on any **string literal** containing
`[ąćęłńóśźżĄĆĘŁŃÓŚŹŻ]` outside an explicit allowlist. Stripping comments is not
optional — `hotkey_binding.dart` carries a comment about ą/ć/ę/ł/ń/ó/ś/ź/ż
explaining the AltGr reasoning, and a scanner that flagged prose would be turned
off within a week.

Allowlist, each entry with its reason in the test source:

| File | Reason |
| --- | --- |
| `recordings/data/markdown_note_vault.dart` | the `ą→a` transliteration map — data, not display text |
| `enrichment/domain/enrichment_defaults.dart` | Polish examples *inside an English LLM prompt*, teaching the model to recognise Polish imperatives (`"zróbmy"`, `"dodaj"`). Removing them would degrade classification. |

The allowlist is by file path with a written reason, matching how
`rebrand_test.dart` pins values: a bare regex with no explanation is a test the
next person deletes instead of understanding.

**What the guard cannot catch, stated so nobody assumes otherwise:** Polish
without diacritics. `'Schowek jest pusty'` would pass. The guard is a tripwire
for the common case, not a proof of English.

### 4. One judgement call made under a stated assumption

`config_tab.dart:368` renders `'ACTIVE · 101/101 files uploaded (0 zł egress)'`.
No diacritics, so the guard would not catch it, but `zł` in an English UI is the
same inconsistency. This was raised and left unanswered.

**Assumption taken: change it to `$0`.** Turso bills in USD, so this reads as a
placeholder rather than a deliberate localisation. Trivially reversible if wrong.

## Testing

- `test/gamification_test.dart`: the two assertions on `title` lose their
  subject. They become assertions on `count` and `type` — the facts the domain
  now owns.
- New `test/gamification_copy_test.dart`: asserts the English wording and that
  the threshold cascade still maps each count to the intended tier. The wording
  assertion belongs wherever the wording lives. A separate file rather than a
  group in `test/gamification_test.dart` because `milestoneCopyFor` returns
  `IconData` and `Color`, so its test imports Flutter — and keeping the domain
  test pure Dart is the property this refactor exists to create.
- `test/widget/celebration_overlay_test.dart`: check whether it constructs a
  `Milestone` directly; if so it needs the shortened constructor.
- `test/language_test.dart`: **prove it is not vacuous.** Re-introduce one Polish
  string, watch it fail, remove it. Per `CLAUDE.md`, a guard that has never been
  seen red is an assumption.
- `flutter analyze && flutter test` is the gate; there is no CI.

## Risks

- **`celebration_overlay.dart` is animated.** Per `CLAUDE.md`, never
  `pumpAndSettle` a screen with a repeating animation. If its widget test already
  pumps explicit frames, nothing changes; if the refactor tempts a rewrite of that
  test, keep the frame-by-frame pumping.
- **The guard's allowlist is a maintenance surface.** Two entries today. If it
  grows past roughly five, that is a signal the rule is wrong rather than that
  the list needs another line.
