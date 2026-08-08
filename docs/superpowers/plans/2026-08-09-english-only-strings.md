# English-only UI strings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the 44 Polish user-facing strings from `lib/`, move milestone copy out of `domain/` into `presentation/`, and add a tripwire test so the drift cannot silently return.

**Architecture:** Three independent tasks. Task 1 shrinks `Milestone` to the fact it owns (`id`, `type`, `count`) and moves title/description/icon/colour into a new `milestone_copy.dart` in `presentation/` — which is what removes `package:flutter/material.dart` from a `domain/` file. Task 2 translates the clipboard feature and collapses a duplicated default-collection list into one definition. Task 3 adds `test/language_test.dart` and proves it is not vacuous.

**Tech Stack:** Flutter (Dart SDK `>=3.10.0 <4.0.0`), `flutter_test`. No new dependencies — this change deliberately adds no i18n infrastructure.

**Spec:** `docs/superpowers/specs/2026-08-09-english-only-strings-design.md`

## Global Constraints

- **No i18n infrastructure.** No `flutter_localizations`, no `intl`, no ARB files, no `l10n.yaml`. `pubspec.yaml` must not gain a dependency in this change.
- **Translations are 1:1.** Do not reword, shorten, or "improve" any string beyond translating it. Preserving wording is what keeps the suite's 367 text assertions undisturbed.
- **No data migration.** Strings already written to disk keep whatever they were saved as. Only code literals change. This covers clipboard collection names and `ClipboardItem.preview`.
- **Do not move the milestone hex colours into `ConsolePalette`**, even though `CLAUDE.md` says every raw hex belongs there. That is a separate debt; mixing it in would put a colour regression and a translation regression in one diff.
- **No `const` constructor may be added to a widget that paints a `Console` palette colour.** `CLAUDE.md` explains why: Flutter skips rebuilding a child `identical` to the previous one, so a `const` widget keeps painting the old theme after a swap. `prefer_const_constructors_in_immutables` is off in `analysis_options.yaml` for exactly this reason. Do not "tidy up" by adding `const`.
- **Gate for every task:** `flutter analyze && flutter test` must be clean before the commit. There is no CI; this is the only gate.
- **Commit messages:** plain subject line, body only when it explains something the diff cannot. No tool attribution, no co-author trailers.

---

### Task 1: Milestone copy moves to presentation

**Files:**
- Modify: `lib/features/gamification/domain/milestone.dart` (rewrite — drops 4 fields and the Flutter import)
- Create: `lib/features/gamification/presentation/milestone_copy.dart`
- Modify: `lib/features/gamification/presentation/celebration_overlay.dart:121-190`
- Modify: `test/gamification_test.dart:40-59`
- Create: `test/gamification_copy_test.dart`
- Modify: `test/widget/celebration_overlay_test.dart:33-48`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `class Milestone { final String id; final MilestoneType type; final int count; }` — constructor `const Milestone({required this.id, required this.type, required this.count})`. Statics `Milestone.isMilestoneCount(int) → bool`, `Milestone.check({required MilestoneType type, required int currentCount, required Set<String> unlockedIds}) → Milestone?`, `Milestone.create({required MilestoneType type, required int count, required String id}) → Milestone` all keep their current signatures.
  - `({String title, String description, IconData icon, Color color}) milestoneCopyFor(Milestone milestone)` in `milestone_copy.dart`.

- [ ] **Step 1: Update the domain test to assert facts instead of wording**

`test/gamification_test.dart` currently asserts on `.title`, which is about to stop existing. Replace the body of the test at lines 40–59 with:

```dart
    test('creates milestones for 1st and 100th done', () {
      final Milestone? firstDone = Milestone.check(
        type: MilestoneType.captureDone,
        currentCount: 1,
        unlockedIds: const <String>{},
      );

      expect(firstDone, isNotNull);
      expect(firstDone!.id, equals('done_1'));
      expect(firstDone.count, equals(1));
      expect(firstDone.type, equals(MilestoneType.captureDone));

      final Milestone? hundredDone = Milestone.check(
        type: MilestoneType.captureDone,
        currentCount: 100,
        unlockedIds: const <String>{},
      );
      expect(hundredDone, isNotNull);
      expect(hundredDone!.id, equals('done_100'));
      expect(hundredDone.count, equals(100));
    });
```

Also rename the test from `'creates milestone details for 1st, 10th, 100th done and captures'` to `'creates milestones for 1st and 100th done'` — the old name promised details this test no longer checks.

- [ ] **Step 2: Write the failing copy test**

Create `test/gamification_copy_test.dart`:

```dart
import 'package:augustyniak_capture/features/gamification/domain/milestone.dart';
import 'package:augustyniak_capture/features/gamification/presentation/milestone_copy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Milestone milestone(MilestoneType type, int count) => Milestone(
        id: '${type == MilestoneType.captureDone ? 'done' : 'capture'}_$count',
        type: type,
        count: count,
      );

  group('milestoneCopyFor', () {
    test('names the first capture and the first done differently', () {
      expect(
        milestoneCopyFor(milestone(MilestoneType.captureDone, 1)).title,
        equals('FIRST ONE DONE!'),
      );
      expect(
        milestoneCopyFor(milestone(MilestoneType.captureCreated, 1)).title,
        equals('FIRST CAPTURE!'),
      );
    });

    test('gives the 100th done its own wording', () {
      expect(
        milestoneCopyFor(milestone(MilestoneType.captureDone, 100)).title,
        equals('A HUNDRED DONE (100)!'),
      );
    });

    test('falls back to the counted wording above 300', () {
      final copy = milestoneCopyFor(milestone(MilestoneType.captureDone, 500));
      expect(copy.title, equals('500 DONE!'));
      expect(copy.icon, equals(Icons.celebration_rounded));
    });

    test('every tier maps to a distinct icon up to 300', () {
      final List<IconData> icons = <int>[1, 10, 20, 50, 100, 200, 300]
          .map((int c) => milestoneCopyFor(milestone(MilestoneType.captureDone, c)).icon)
          .toList();
      expect(icons.toSet().length, equals(icons.length));
    });

    test('no copy contains a Polish diacritic', () {
      final RegExp polish = RegExp('[ąćęłńóśźżĄĆĘŁŃÓŚŹŻ]');
      for (final MilestoneType type in MilestoneType.values) {
        for (final int count in <int>[1, 10, 20, 50, 100, 200, 300, 400]) {
          final copy = milestoneCopyFor(milestone(type, count));
          expect(copy.title, isNot(matches(polish)), reason: 'title for $type/$count');
          expect(copy.description, isNot(matches(polish)), reason: 'description for $type/$count');
        }
      }
    });
  });
}
```

- [ ] **Step 3: Run both tests to verify they fail**

Run: `flutter test test/gamification_copy_test.dart test/gamification_test.dart`
Expected: `gamification_copy_test.dart` FAILS to compile — `Error: Couldn't resolve the package ... milestone_copy.dart` and `Too few positional arguments` / `required named parameter 'title'` on the `Milestone(...)` helper. `gamification_test.dart` FAILS to compile on the removed `.title`. Both failures are the point: they prove the new shape does not exist yet.

- [ ] **Step 4: Rewrite `milestone.dart` as pure Dart**

Replace the entire contents of `lib/features/gamification/domain/milestone.dart` with:

```dart
/// A threshold the user has just crossed.
///
/// This type carries the *fact* — which threshold, of which kind, and the
/// stable id that records it as unlocked. It deliberately carries no wording,
/// icon or colour: those are one widget's concern, they would drag
/// `package:flutter/material.dart` into `domain/`, and they are what a future
/// translation pass would have to reach into the domain to change. See
/// `presentation/milestone_copy.dart`.
enum MilestoneType {
  captureCreated,
  captureDone,
}

class Milestone {
  const Milestone({
    required this.id,
    required this.type,
    required this.count,
  });

  final String id;
  final MilestoneType type;
  final int count;

  static bool isMilestoneCount(int count) {
    if (count <= 0) return false;
    if (count == 1 ||
        count == 10 ||
        count == 20 ||
        count == 50 ||
        count == 100 ||
        count == 200 ||
        count == 300) {
      return true;
    }
    return count >= 400 && count % 100 == 0;
  }

  static Milestone? check({
    required MilestoneType type,
    required int currentCount,
    required Set<String> unlockedIds,
  }) {
    if (!isMilestoneCount(currentCount)) return null;

    final String prefix = type == MilestoneType.captureCreated ? 'capture' : 'done';
    final String id = '${prefix}_$currentCount';

    if (unlockedIds.contains(id)) return null;

    return create(type: type, count: currentCount, id: id);
  }

  static Milestone create({
    required MilestoneType type,
    required int count,
    required String id,
  }) {
    return Milestone(id: id, type: type, count: count);
  }
}
```

- [ ] **Step 5: Create `milestone_copy.dart`**

Create `lib/features/gamification/presentation/milestone_copy.dart`:

```dart
import 'package:flutter/material.dart';

import '../domain/milestone.dart';

/// The words, icon and colour for a crossed threshold.
///
/// Lives in `presentation/` rather than on [Milestone] because it is one
/// widget's concern and because `IconData`/`Color` would otherwise pull Flutter
/// into `domain/`. The threshold cascade below mirrors
/// [Milestone.isMilestoneCount]: 1, 10, 20, 50, 100, 200, 300, then every
/// further 100. If a threshold is added there, add its tier here — the fallback
/// will otherwise absorb it silently.
///
/// The raw hex colours are inherited verbatim from the previous location.
/// `CLAUDE.md` says every raw hex belongs in `ConsolePalette`; these do not yet,
/// and moving them is deliberately a separate change.
({String title, String description, IconData icon, Color color}) milestoneCopyFor(
  Milestone milestone,
) {
  final bool isDone = milestone.type == MilestoneType.captureDone;
  final int count = milestone.count;

  if (count == 1) {
    return (
      title: isDone ? 'FIRST ONE DONE!' : 'FIRST CAPTURE!',
      description: isDone
          ? 'You marked your first note as done. Great start!'
          : 'Your first capture is saved. Keep it up!',
      icon: isDone ? Icons.check_circle_outline_rounded : Icons.bolt_rounded,
      color: isDone ? const Color(0xFF10B981) : const Color(0xFF6366F1),
    );
  }

  if (count == 10) {
    return (
      title: isDone ? '10 DONE!' : '10 CAPTURES!',
      description: isDone
          ? '10 items ticked off! You are picking up pace.'
          : '10 thoughts and recordings captured. Good habit!',
      icon: isDone ? Icons.stars_rounded : Icons.auto_awesome_rounded,
      color: isDone ? const Color(0xFF059669) : const Color(0xFF8B5CF6),
    );
  }

  if (count == 20) {
    return (
      title: isDone ? '20 DONE!' : '20 CAPTURES!',
      description: isDone
          ? '20 items completed! Your inbox is clearing.'
          : '20 entries created. Your head is full of ideas!',
      icon: isDone ? Icons.emoji_events_rounded : Icons.local_fire_department_rounded,
      color: isDone ? const Color(0xFF10B981) : const Color(0xFFEC4899),
    );
  }

  if (count == 50) {
    return (
      title: isDone ? '50 DONE!' : '50 CAPTURES!',
      description: isDone
          ? 'Half a hundred closed! Remarkable productivity.'
          : '50 thoughts archived. The system is working.',
      icon: isDone ? Icons.workspace_premium_rounded : Icons.rocket_launch_rounded,
      color: isDone ? const Color(0xFFF59E0B) : const Color(0xFF3B82F6),
    );
  }

  if (count == 100) {
    return (
      title: isDone ? 'A HUNDRED DONE (100)!' : '100 CAPTURES!',
      description: isDone
          ? 'One hundred tasks completed! You are a master of closing.'
          : '100 entries in the base! Your second brain is growing.',
      icon: isDone ? Icons.military_tech_rounded : Icons.diamond_rounded,
      color: const Color(0xFFEAB308),
    );
  }

  if (count == 200) {
    return (
      title: isDone ? '200 DONE!' : '200 CAPTURES!',
      description: isDone
          ? '200 topics closed. A real work machine!'
          : '200 recordings and notes in the system. Remarkable!',
      icon: Icons.shield_rounded,
      color: const Color(0xFFA855F7),
    );
  }

  if (count == 300) {
    return (
      title: isDone ? '300 DONE!' : '300 CAPTURES!',
      description: isDone
          ? '300 items completed! Absolute expert level.'
          : '300 captures! Full flow of information.',
      icon: Icons.verified_rounded,
      color: const Color(0xFF06B6D4),
    );
  }

  // Every 100 further (400, 500, 600...)
  return (
    title: isDone ? '$count DONE!' : '$count CAPTURES!',
    description: isDone
        ? '$count tasks completed. Impressive consistency!'
        : '$count notes and recordings saved!',
    icon: Icons.celebration_rounded,
    color: const Color(0xFFF43F5E),
  );
}
```

- [ ] **Step 6: Point `celebration_overlay.dart` at the new function**

Add the import beside the existing `import '../domain/milestone.dart';`:

```dart
import 'milestone_copy.dart';
```

Inside `build`, immediately after the line that reads `final double scale = ...` (around line 99) and before the `return Opacity(`, resolve the copy once:

```dart
                final copy = milestoneCopyFor(_currentMilestone!);
```

Then replace the six `_currentMilestone!.<field>` reads in the subtree:

| Line (before) | From | To |
| --- | --- | --- |
| 121 | `_currentMilestone!.color.withValues(alpha: 0.6)` | `copy.color.withValues(alpha: 0.6)` |
| 126 | `_currentMilestone!.color.withValues(alpha: 0.35)` | `copy.color.withValues(alpha: 0.35)` |
| 140 | `_currentMilestone!.color.withValues(alpha: 0.15)` | `copy.color.withValues(alpha: 0.15)` |
| 142 | `_currentMilestone!.color` | `copy.color` |
| 147 | `_currentMilestone!.icon` | `copy.icon` |
| 149 | `_currentMilestone!.color` | `copy.color` |
| 154 | `_currentMilestone!.title` | `copy.title` |
| 165 | `_currentMilestone!.description` | `copy.description` |
| 177 | `_currentMilestone!.color` | `copy.color` |

And at line 185, translate the button label:

```dart
                                    child: Text(
                                      'AWESOME!',
```

- [ ] **Step 7: Update the overlay widget test**

In `test/widget/celebration_overlay_test.dart`, replace the five Polish assertions:

```dart
    expect(find.text('Main Content'), findsOneWidget);
    expect(find.text('FIRST ONE DONE!'), findsNothing);

    // Trigger first done milestone
    await controller.onCaptureDone(1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('FIRST ONE DONE!'), findsOneWidget);
    expect(find.text('AWESOME!'), findsOneWidget);

    // Dismiss by tapping button
    await tester.tap(find.text('AWESOME!'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    expect(find.text('FIRST ONE DONE!'), findsNothing);
```

Note this test pumps explicit frames rather than calling `pumpAndSettle` — the overlay animates, and per `CLAUDE.md` a settling call on an animated screen hangs until timeout. Keep it that way.

- [ ] **Step 8: Run the gamification tests**

Run: `flutter test test/gamification_test.dart test/gamification_copy_test.dart test/widget/celebration_overlay_test.dart`
Expected: PASS, all three files.

- [ ] **Step 9: Verify the domain file no longer imports Flutter**

Run: `grep -c "package:flutter" lib/features/gamification/domain/milestone.dart`
Expected: `0`

- [ ] **Step 10: Full gate**

Run: `flutter analyze && flutter test`
Expected: no analyzer issues; entire suite green.

- [ ] **Step 11: Commit**

```bash
git add lib/features/gamification test/gamification_test.dart \
        test/gamification_copy_test.dart test/widget/celebration_overlay_test.dart
git commit -m "Move milestone copy out of the domain and into English

Milestone carried title, description, icon and colour for one widget, which
is why a domain file imported material.dart. It now carries the fact — id,
type, count — and milestoneCopyFor in presentation/ carries the words.

The domain test asserted on wording it no longer owns; that assertion moved
to gamification_copy_test.dart, where the wording lives."
```

---

### Task 2: Translate the clipboard feature and unify its default collections

**Files:**
- Modify: `lib/features/clipboard/domain/clipboard_watcher_service.dart:104`
- Modify: `lib/features/clipboard/presentation/clipboard_history_sheet.dart` (22 strings, plus the duplicated default list at 246-249 and 318-321)
- Modify: `test/clipboard_history_test.dart:165`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `const List<String> kDefaultClipboardCollections` — a file-level constant in `clipboard_history_sheet.dart`, value `<String>['Favorites', 'Code', 'Prompts', 'Important']`.

- [ ] **Step 1: Update the failing UI assertion in the clipboard test**

In `test/clipboard_history_test.dart`, line 165:

```dart
      expect(find.text('Clipboard is empty'), findsOneWidget);
```

Leave lines 21–79 alone. They use `'Kod'`, `'Ulubione'` and `'Prompty'` as arbitrary collection-name *data* in round-trip assertions, not as UI copy — the point of those tests is that any string round-trips, and the guard in Task 3 scans `lib/` only.

- [ ] **Step 2: Run it to verify it fails**

Run: `flutter test test/clipboard_history_test.dart`
Expected: FAIL — `Expected: exactly one matching candidate / Actual: _TextFinder:<zero widgets with text "Clipboard is empty">`. The widget still renders `'Schowek jest pusty'`.

- [ ] **Step 3: Translate the persisted image preview**

In `lib/features/clipboard/domain/clipboard_watcher_service.dart`, line 104:

```dart
          preview: '[Image]',
```

This value is written to the repository and persisted. Existing rows keep `[Obrazek]` — do not write a migration.

- [ ] **Step 4: Add the single default-collection definition**

In `lib/features/clipboard/presentation/clipboard_history_sheet.dart`, add near the top of the file, after the imports and before the first class:

```dart
/// Seed vocabulary for clipboard collections, offered both as naming
/// suggestions in the "add to collection" sheet and as filter chips.
///
/// One definition on purpose: these were two literal lists that had already
/// drifted apart — the chip list was missing `Important`. Same rule as
/// `_matches()` in `queue_tab.dart`, where one definition serves both the
/// filter and its counts so the two cannot disagree.
///
/// Translating these does not rename anything already saved. A user with items
/// tagged `Ulubione` sees both a `Favorites` chip (this default, empty) and an
/// `Ulubione` chip (their data), because the chip list is these defaults
/// unioned with the collections actually in use.
const List<String> kDefaultClipboardCollections = <String>[
  'Favorites',
  'Code',
  'Prompts',
  'Important',
];
```

- [ ] **Step 5: Replace both duplicated lists with the constant**

At lines 245–251, the suggestion set becomes:

```dart
    final Set<String> defaultSuggestions = <String>{
      ...kDefaultClipboardCollections,
      ...existingCollections,
    };
```

At lines 318–323, the chip set becomes:

```dart
        final Set<String> collections = <String>{
          ...kDefaultClipboardCollections,
          ...widget.watcherService.allCollections,
        };
```

- [ ] **Step 6: Translate the remaining 19 strings in the sheet**

Apply exactly these, 1:1, no rewording:

| Line | From | To |
| --- | --- | --- |
| 62 | `'Przed chwilą'` | `'Just now'` |
| 63 | `'${diff.inMinutes} min temu'` | `'${diff.inMinutes} min ago'` |
| 64 | `'${diff.inHours}h temu'` | `'${diff.inHours}h ago'` |
| 104 | `'Obraz przekazano do analizy Vision LLM / OCR ✨'` | `'Image sent for Vision LLM / OCR analysis ✨'` |
| 133 | `'Przekazano do przetworzenia LLM (Capture ✨)'` | `'Sent to LLM processing (Capture ✨)'` |
| 194 | `'NOWA KOLEKCJA'` | `'NEW COLLECTION'` |
| 206 | `'Nazwa kolekcji (np. Prompty, Kod)...'` | `'Collection name (e.g. Prompts, Code)...'` |
| 215 | `'Anuluj'` | `'Cancel'` |
| 225 | `'Dodaj'` | `'Add'` |
| 270 | `'DODAJ DO KOLEKCJI'` | `'ADD TO COLLECTION'` |
| 389 | `'SCHOWEK SYSTEMOWY'` | `'SYSTEM CLIPBOARD'` |
| 410 | `'Wyczyszcz'` | `'Clear'` |
| 428 | `'Pisz aby szukać... (użyj ↑ ↓ oraz Enter)'` | `'Type to search... (use ↑ ↓ and Enter)'` |
| 477 | `'Wszystkie'` | `'All'` |
| 522 | `'Nowa'` | `'New'` |
| 549 | `'Schowek jest pusty'` | `'Clipboard is empty'` |
| 550 | `'Brak wyników w tej kolekcji / wyszukiwaniu'` | `'No results in this collection / search'` |
| 717 | `'Przekaż do przetworzenia LLM (Capture ✨)'` | `'Send to LLM processing (Capture ✨)'` |
| 779 | `'[Nie można wczytać obrazu]'` | `'[Could not load image]'` |

Line numbers shift as you edit — match on the Polish string, not the number.

`'Wszystkie' → 'All'` is safe despite `CLAUDE.md` reserving `ANY` over `ALL` in the queue: that rule is about the Queue tab's review strip colliding with its status row, and this is a different screen with no `ALL` chip beside it.

- [ ] **Step 7: Run the clipboard tests**

Run: `flutter test test/clipboard_history_test.dart test/clipboard_test.dart`
Expected: PASS.

- [ ] **Step 8: Verify no Polish remains in the clipboard feature**

Run: `grep -rnE "'[^']*(ą|ć|ę|ł|ń|ó|ś|ź|ż|Obrazek|Anuluj|Dodaj|Wszystkie|temu|Schowek)" lib/features/clipboard --include='*.dart'`
Expected: no output (exit 1).

- [ ] **Step 9: Full gate**

Run: `flutter analyze && flutter test`
Expected: no analyzer issues; entire suite green.

- [ ] **Step 10: Commit**

```bash
git add lib/features/clipboard test/clipboard_history_test.dart
git commit -m "Translate the clipboard feature to English

The default collection names were two literal lists that had already drifted
— the filter chips were missing Important — so they collapse into one
constant rather than being translated twice.

Nothing on disk is renamed. '[Obrazek]' is persisted into ClipboardItem
.preview, so the literal changes and existing rows keep what they were saved
as; a user's own collections keep their Polish names and still appear as
chips alongside the new defaults."
```

---

### Task 3: The tripwire

**Files:**
- Create: `test/language_test.dart`
- Modify: `lib/features/settings/presentation/config_tab.dart:369`

**Interfaces:**
- Consumes: Tasks 1 and 2 must be complete, or this test fails on their strings.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Fix the currency literal**

In `lib/features/settings/presentation/config_tab.dart`, line 369:

```dart
                      ? 'ACTIVE · 101/101 files uploaded ($0 egress)'
```

Careful: `$0` inside a normal Dart string is **not** interpolation (`$` followed by a digit is a literal `$`), so this compiles as written. If the analyzer complains, use `'\$0'`.

Note in passing, and do **not** fix here: the `101/101` in that string is hardcoded, not read from any state. Wiring it to real R2 progress is a different change.

- [ ] **Step 2: Write the guard**

Create `test/language_test.dart`:

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `CLAUDE.md`: "user-facing strings in code are English (they were Polish
/// until the design pass — do not reintroduce Polish)". Nothing enforced that
/// until this file, and two features drifted back.
///
/// **This is a tripwire, not a proof.** The diacritic scan is structural and
/// needs no upkeep. The wordlist is a heuristic with false negatives by
/// construction: a Polish string using none of those words passes. It exists
/// because a diacritic-only scan of this repository missed nine strings —
/// 'WSPANIALE!', 'Anuluj', 'Dodaj', 'Wszystkie', 'Nowa', 'Wyczyszcz',
/// '[Obrazek]', 'min temu', 'Schowek jest pusty' — and reported one of their
/// files as clean. Do not read a green run here as "the UI is English".
void main() {
  // Files allowed to hold Polish, each for a reason that is not display text.
  const Map<String, String> allowed = <String, String>{
    'lib/features/recordings/data/markdown_note_vault.dart':
        'the ą→a transliteration map — data, not display text',
    'lib/features/enrichment/domain/enrichment_defaults.dart':
        'Polish examples inside an English LLM prompt, teaching the model to '
        'recognise Polish imperatives. Removing them degrades classification.',
  };

  // One pass, left to right, so a `//` inside a string literal is consumed as
  // part of the literal rather than treated as the start of a comment. Order
  // matters: triple quotes before single, raw strings before bare.
  final RegExp tokens = RegExp(
    r"r?'''[\s\S]*?'''"
    r'|r?"""[\s\S]*?"""'
    r"|r?'(?:[^'\\\n]|\\.)*'"
    r'|r?"(?:[^"\\\n]|\\.)*"'
    r'|//[^\n]*'
    r'|/\*[\s\S]*?\*/',
  );

  final RegExp diacritics = RegExp('[ąćęłńóśźżĄĆĘŁŃÓŚŹŻ]');
  final RegExp polishWords = RegExp(
    r'\b(nie|jest|oraz|aby|temu|przez|dla|lub|brak|wszystkie|anuluj|dodaj'
    r'|usuń|nowa|nowy|pusty|obrazek|kolekcja|wyczyść|zapisz|zamknij|otwórz'
    r'|szukaj|wspaniale|nazwa|schowek)\b',
    caseSensitive: false,
  );

  test('no Polish in user-facing string literals under lib/', () {
    final List<String> offences = <String>[];

    final List<File> sources = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((File f) => f.path.endsWith('.dart'))
        .toList();

    expect(sources, isNotEmpty, reason: 'run this from the repository root');

    for (final File file in sources) {
      final String relative = file.path.replaceAll(r'\', '/');
      if (allowed.containsKey(relative)) continue;

      final String source = file.readAsStringSync();
      for (final RegExpMatch match in tokens.allMatches(source)) {
        final String token = match.group(0)!;
        if (token.startsWith('//') || token.startsWith('/*')) continue;

        if (!diacritics.hasMatch(token) && !polishWords.hasMatch(token)) {
          continue;
        }

        final int line = '\n'.allMatches(source.substring(0, match.start)).length + 1;
        offences.add('$relative:$line  $token');
      }
    }

    expect(
      offences,
      isEmpty,
      reason: 'Polish string literals found. Translate them, or — if the text '
          'is data rather than display copy — add the file to `allowed` above '
          'with the reason:\n${offences.join('\n')}',
    );
  });

  test('every allowlisted file exists', () {
    // An allowlist entry for a moved or deleted file is a silent hole: the
    // scan would skip nothing and nobody would know the reason had expired.
    for (final String path in allowed.keys) {
      expect(File(path).existsSync(), isTrue, reason: '$path is allowlisted but missing');
    }
  });
}
```

- [ ] **Step 3: Run it**

Run: `flutter test test/language_test.dart`
Expected: PASS — Tasks 1 and 2 removed everything it looks for.

If it fails, read the offences it prints. Two legitimate outcomes: a string Task 1 or 2 missed (translate it), or a false positive from the wordlist on genuinely English copy (in which case narrow the word, do not widen the allowlist — a file-level allowlist entry disables the scan for that whole file).

- [ ] **Step 4: Prove the guard is not vacuous**

`CLAUDE.md`: a test written after the fix that has never been seen red is an assumption, not a check. Verify both halves independently.

First the diacritic half. Copy the file you are about to edit into the scratchpad — **do not use `git checkout --` to undo this**, it reverts to `HEAD` and takes every other uncommitted change in the file with it:

```bash
cp lib/features/clipboard/presentation/clipboard_history_sheet.dart /tmp/guard-check.dart
```

Change `'Just now'` back to `'Przed chwilą'`, then:

Run: `flutter test test/language_test.dart`
Expected: FAIL, naming `lib/features/clipboard/presentation/clipboard_history_sheet.dart:62  'Przed chwilą'`

Now the wordlist half. Change it instead to `'Nowa'` (no diacritic):

Run: `flutter test test/language_test.dart`
Expected: FAIL, naming the same file and line with `'Nowa'`. If this one passes, the wordlist branch is dead and the guard is only half of what it claims.

Restore:

```bash
cp /tmp/guard-check.dart lib/features/clipboard/presentation/clipboard_history_sheet.dart
rm /tmp/guard-check.dart
```

Run: `flutter test test/language_test.dart`
Expected: PASS.

- [ ] **Step 5: Full gate**

Run: `flutter analyze && flutter test`
Expected: no analyzer issues; entire suite green.

- [ ] **Step 6: Commit**

```bash
git add test/language_test.dart lib/features/settings/presentation/config_tab.dart
git commit -m "Guard against Polish returning to lib/ string literals

Scans string literals for Polish diacritics and for a short list of Polish
function words, skipping comments so the AltGr note in hotkey_binding.dart
does not trip it. Two files are allowlisted with reasons: the note vault's
transliteration map, and the Polish examples inside the enrichment prompt.

The wordlist half is not redundant. A diacritic-only scan of this repository
missed nine strings and called one of their files clean. It is still a
tripwire rather than a proof, and the file says so."
```

---

## After the plan

Two things this change deliberately leaves standing, recorded so they are not mistaken for oversights:

- **`config_tab.dart` reports a hardcoded `101/101` media-sync progress.** Found while fixing the currency in that same string. Needs real R2 state; unrelated to language.
- **The milestone hex colours are still raw hexes outside `ConsolePalette`**, now in `presentation/` where the rule is least ambiguous. That is the natural next cleanup.

One timing note: `docs/superpowers/specs/2026-08-09-clipboard-item-editing-design.md` is an approved spec for new clipboard UI. Landing Task 3 before that feature is implemented is what stops it introducing a new batch of Polish strings.
