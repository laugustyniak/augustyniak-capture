# English-only UI strings, and the layering fix that makes i18n cheap later

Date: 2026-08-09
Status: approved, ready for implementation planning

## Problem

Two features shipped with Polish user-facing strings while the rest of the app is
English. `CLAUDE.md` already states the rule — "user-facing strings in code are
English (they were Polish until the design pass — do not reintroduce Polish)" —
but nothing enforces it, so the drift was invisible until someone read the
screens.

The Polish is not scattered. It sits in two features, across four files:

| File | Polish strings | Layer |
| --- | --- | --- |
| `gamification/domain/milestone.dart` | 20 | `domain/` |
| `gamification/presentation/celebration_overlay.dart` | 1 (`'WSPANIALE!'`) | `presentation/` |
| `clipboard/domain/clipboard_watcher_service.dart` | 1 (`'[Obrazek]'`) | `domain/` |
| `clipboard/presentation/clipboard_history_sheet.dart` | 22 | `presentation/` |

**This inventory was corrected upward during planning, and how it was missed is
the point.** The first pass grepped for `[ąćęłńóśźż]` and reported 31 strings in
two files. It missed `'WSPANIALE!'`, `'Anuluj'`, `'Dodaj'`, `'Wszystkie'`,
`'Nowa'`, `'Wyczyszcz'`, `'[Obrazek]'`, `'min temu'` and `'Schowek jest pusty'` —
nine strings, one of them in a file the report claimed was clean — because none
of them contains a diacritic. A second pass with a Polish-wordlist grep found
them and confirmed nothing leaked outside these four files. This is the same
failure the guard in section 3 is explicitly documented as *not* preventing.

The clipboard sheet is a plain translation. `milestone.dart` is not: those
sentences are
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

### 2. The clipboard feature — translation, plus two things that are not

Twenty-two UI strings in `clipboard_history_sheet.dart` become English, 1:1,
including the relative-time strings at lines 62–64 (`'Przed chwilą'`,
`'min temu'`, `'h temu'`).

**Two findings are not translations and need a decision each.**

**a. `'[Obrazek]'` is persisted, not displayed.**
`clipboard_watcher_service.dart:104` writes it into `ClipboardItem.preview`, which
goes to the repository and onto disk. `CLAUDE.md` rules on this class: "Strings
already stored on disk keep whatever they were saved as; only code literals were
translated." So the literal becomes `'[Image]'` and **nothing migrates existing
rows** — clipboard entries captured before this change keep `[Obrazek]` in their
preview. Same reasoning applies to collection names below.

**b. The default collection list is duplicated, and the two copies already
disagree.** Lines 246–249 offer `Ulubione / Kod / Prompty / Ważne` as suggestions
in the "add to collection" dialog; lines 318–321 seed the filter chips with
`Ulubione / Kod / Prompty` — `Ważne` is missing. Two definitions of one
vocabulary, already drifted.

Unifying them into a single `const List<String> _defaultCollections` is **in
scope**, because the alternative is translating both copies and leaving two
English lists that still disagree — strictly worse than what exists now. This is
the rule `CLAUDE.md` states for `_matches()` in `queue_tab.dart`: one definition,
used by both the filter and the counts, "so the two cannot disagree".

**Consequence the user will see, stated so it is not mistaken for a bug:** the
filter chips are seeded from the defaults *unioned with the user's existing
collections*. After this change someone with items tagged `Ulubione` sees both a
`Favorites` chip (the new default, empty) and an `Ulubione` chip (their data,
populated). That is the honest rendering of "code literals translated, stored
data untouched". Renaming a user's collections to match a code change is the
class of action this repo refuses everywhere else.

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

**A diacritic scan alone is demonstrably not enough**, so the guard has a second
check. Nine of the 44 Polish strings in this codebase carry no diacritic at all —
`'WSPANIALE!'`, `'Anuluj'`, `'Dodaj'`, `'Wszystkie'`, `'Nowa'`, `'Wyczyszcz'`,
`'[Obrazek]'`, `'min temu'`, `'Schowek jest pusty'` — and a diacritic-only scan
reported one of their files as clean. That is not a hypothetical; it happened
during the planning of this very change.

So the guard also matches a small list of Polish function words and UI verbs that
effectively never appear in English UI copy, case-insensitively and on word
boundaries:

```
nie, jest, oraz, aby, temu, przez, dla, lub, brak, wszystkie, anuluj,
dodaj, usuń, nowa, nowy, pusty, obrazek, kolekcja, wyczyść, zapisz,
zamknij, otwórz, szukaj, wspaniale, nazwa, schowek
```

**Stated plainly: this second check is a heuristic, not a proof.** A wordlist has
false negatives by construction — a Polish string using none of these words
passes. It also has a maintenance cost, and the honest expectation is that it
catches the next accident rather than every possible one. The diacritic half is
structural and needs no upkeep; the wordlist half is a tripwire that will
occasionally need a word added. Neither makes the file a guarantee that the UI is
English, and the test's own doc comment must say so, or the next reader will
trust it further than it deserves.

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
- `test/widget/celebration_overlay_test.dart`: asserts `find.text('PIERWSZE
  UKOŃCZONE!')` (three times) and `find.text('WSPANIALE!')` (twice, one of them a
  `tap` target). All five become the English wording. It does not construct a
  `Milestone` directly, so the shortened constructor does not reach it.
- `test/clipboard_history_test.dart:165`: asserts `find.text('Schowek jest
  pusty')` — becomes the English wording.
- `test/clipboard_history_test.dart` lines 21–79 use `'Kod'`, `'Ulubione'` and
  `'Prompty'` as **arbitrary collection-name data** in round-trip assertions, not
  as UI copy. They are deliberately left alone: the guard scans `lib/` only, and
  the point of those tests is that any string round-trips.
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
