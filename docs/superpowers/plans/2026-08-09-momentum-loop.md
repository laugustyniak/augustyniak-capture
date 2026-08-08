# Momentum Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record every capture the user *finishes* in a durable append-only log, derive a daily target from their own pace, and give closing a capture visible and audible feedback.

**Architecture:** A new `lib/features/momentum/` feature in the house `domain/data/presentation` layout. Closures are appended to `closures.jsonl` from inside `RecordingsController._update` — the funnel every mutation already passes through — so no closing path can bypass it. `MomentumController` derives everything on read from that log plus a callback into the timer's already-loaded sessions. Four UI surfaces consume it.

**Tech Stack:** Flutter, Dart SDK `>=3.10.0 <4.0.0`, `audioplayers` (already a dependency), `path_provider`, `path`. No new packages.

**Spec:** `docs/superpowers/specs/2026-08-09-momentum-loop-design.md`

## Global Constraints

- **User-facing strings are English.** Polish was removed in a design pass and must not return. Identifiers and comments are English too.
- **No new value on `RecordingStatus` and no new field on `Recording`.** Exactly one new persisted field in the whole feature: `cueSounds` on `AppSettings`.
- **Append-only stores are never rewritten.** `closures.jsonl` uses `FileMode.writeOnlyAppend`, `flush: true`. A row that will not parse is skipped, never fatal.
- **Best-effort under the `ClipboardSink` contract:** update in-memory state first, then write; swallow every error into `LogSink` at `LogLevel.warn`. Never throw into a capture or a close.
- **Calendar arithmetic uses `DateTime(y, m, d ± n)`, never `Duration`.** A `Duration` loses an hour across a DST transition and drops a whole day.
- **No animation may repeat forever.** One-shot `TweenAnimationBuilder` only; no `repeat()`. Anything that loops hangs `pumpAndSettle` for the whole suite.
- **Every widget that paints a palette colour must NOT have a `const` constructor.** `Console`'s colours are mutable globals so the theme can swap at runtime; a `const` widget keeps painting the old palette. Call sites are therefore non-`const` too.
- **Clocks are constructor seams** (`DateTime Function()`), defaulting to `DateTime.now`. No test may sleep for a fixed span.
- **Commit style:** Conventional Commits, matching repo history (`feat(scope): …`, `fix(scope): …`, `test(scope): …`).
- **Gate before every commit:** `flutter analyze && flutter test`. There is no CI; this is the only gate.

## File Structure

**Create:**

| Path | Responsibility |
| --- | --- |
| `lib/features/momentum/domain/closure_event.dart` | `ClosureEvent`, `ClosureKind`, `ClosureLog`, `NoopClosureLog` |
| `lib/features/momentum/domain/momentum_snapshot.dart` | `DayClosures`, `closuresByDay`, `paceOf`, `targetFrom`, `MomentumSnapshot` |
| `lib/features/momentum/domain/cue_player.dart` | `Cue`, `CuePlayer`, `NoopCuePlayer` |
| `lib/features/momentum/data/file_closure_log.dart` | `FileClosureLog` |
| `lib/features/momentum/data/asset_cue_player.dart` | `AssetCuePlayer` |
| `lib/features/momentum/presentation/momentum_controller.dart` | `MomentumController` |
| `lib/features/momentum/presentation/momentum_panel.dart` | `MomentumPanel` (Timer tab) |
| `lib/features/momentum/presentation/day_closed_card.dart` | `DayClosedCard` (Queue) |
| `assets/sounds/close.wav`, `assets/sounds/day.wav` | vendored cues |
| `test/momentum_closure_test.dart`, `test/momentum_pace_test.dart`, `test/momentum_controller_test.dart`, `test/widget/momentum_panel_test.dart`, `test/widget/day_closed_card_test.dart` | tests |

**Modify:** `recordings_controller.dart` (closure funnel), `queue_tab.dart` (`_closingIds`, card slot), `queue_metrics.dart` (animated counter), `compact_queue_header.dart` (animated segment counts), `timer_tab.dart` (mount panel), `app_settings.dart` + `settings_repository.dart` (`cueSounds`), `config_tab.dart` (toggle), `recordings_page.dart` (wiring), `pubspec.yaml` (assets already globbed — verify).

---

### Task 1: `ClosureEvent` and the log interface

**Files:**
- Create: `lib/features/momentum/domain/closure_event.dart`
- Test: `test/momentum_closure_test.dart`

**Interfaces:**
- Consumes: `CaptureType` from `lib/features/recordings/domain/capture_type.dart`
- Produces: `ClosureEvent({required String recordingId, required DateTime at, required ClosureKind kind, required CaptureType type, String? projectId, String? projectName})`, `ClosureEvent.toJson()`, `static ClosureEvent? fromJson(Object?)`, `enum ClosureKind { review, route, handoff }` with `static ClosureKind? fromName(String?)`, `abstract interface class ClosureLog { Future<List<ClosureEvent>> load(); Future<void> append(ClosureEvent event); }`, `class NoopClosureLog implements ClosureLog`

- [ ] **Step 1: Write the failing tests**

Create `test/momentum_closure_test.dart`:

```dart
import 'package:augustyniak_capture/features/momentum/domain/closure_event.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:test/test.dart';

void main() {
  group('ClosureEvent', () {
    test('round-trips through JSON', () {
      final ClosureEvent event = ClosureEvent(
        recordingId: 'abc',
        at: DateTime(2026, 8, 9, 14, 30),
        kind: ClosureKind.route,
        type: CaptureType.text,
        projectId: 'p1',
        projectName: 'Capture',
      );

      final ClosureEvent? back = ClosureEvent.fromJson(
        Map<String, dynamic>.from(event.toJson()),
      );

      expect(back, isNotNull);
      expect(back!.recordingId, 'abc');
      expect(back.at, DateTime(2026, 8, 9, 14, 30));
      expect(back.kind, ClosureKind.route);
      expect(back.type, CaptureType.text);
      expect(back.projectId, 'p1');
      expect(back.projectName, 'Capture');
    });

    test('omits absent optional fields rather than writing nulls', () {
      final ClosureEvent event = ClosureEvent(
        recordingId: 'abc',
        at: DateTime(2026, 8, 9),
        kind: ClosureKind.review,
        type: CaptureType.audioRecording,
      );

      expect(event.toJson().containsKey('projectId'), isFalse);
      expect(event.toJson().containsKey('projectName'), isFalse);
    });

    test('a row with an unknown kind is dropped, not defaulted', () {
      // Unlike CaptureType.fromName there is no sensible kind to assume, and
      // counting a newer build's kind as `review` would be a quiet lie about
      // how the work left the desk.
      final ClosureEvent? back = ClosureEvent.fromJson(<String, dynamic>{
        'recordingId': 'abc',
        'at': DateTime(2026, 8, 9).toIso8601String(),
        'kind': 'teleported',
        'type': 'text',
      });

      expect(back, isNull);
    });

    test('an unknown capture type still defaults, like CaptureType.fromName', () {
      final ClosureEvent? back = ClosureEvent.fromJson(<String, dynamic>{
        'recordingId': 'abc',
        'at': DateTime(2026, 8, 9).toIso8601String(),
        'kind': 'review',
        'type': 'hologram',
      });

      expect(back, isNotNull);
      expect(back!.type, CaptureType.audioRecording);
    });

    test('a row missing a required field is dropped', () {
      expect(
        ClosureEvent.fromJson(<String, dynamic>{'recordingId': 'abc'}),
        isNull,
      );
      expect(ClosureEvent.fromJson('not a map'), isNull);
      expect(ClosureEvent.fromJson(null), isNull);
    });

    test('an unparseable timestamp is dropped rather than defaulted to now', () {
      expect(
        ClosureEvent.fromJson(<String, dynamic>{
          'recordingId': 'abc',
          'at': 'yesterday-ish',
          'kind': 'review',
          'type': 'text',
        }),
        isNull,
      );
    });
  });

  group('NoopClosureLog', () {
    test('loads nothing and accepts appends', () async {
      const NoopClosureLog log = NoopClosureLog();
      await log.append(
        ClosureEvent(
          recordingId: 'a',
          at: DateTime(2026, 1, 1),
          kind: ClosureKind.review,
          type: CaptureType.text,
        ),
      );
      expect(await log.load(), isEmpty);
    });
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/momentum_closure_test.dart`
Expected: FAIL — `Target of URI doesn't exist: '.../momentum/domain/closure_event.dart'`

- [ ] **Step 3: Write the implementation**

Create `lib/features/momentum/domain/closure_event.dart`:

```dart
import '../../recordings/domain/capture_type.dart';

/// How a capture left the desk.
///
/// [ClosureKind.fromName] returns **null** for an unrecognised value and the
/// caller drops the row — the rule `RouteKind.fromName` follows, and the
/// opposite of `CaptureType.fromName`. There is no sensible kind to assume, and
/// recording a newer build's kind as [review] would claim the user ticked
/// something off by hand when in fact it was delivered somewhere.
enum ClosureKind {
  /// Ticked off by hand — `toggleProcessed`.
  review,

  /// Delivered to the project inbox — `route`.
  route,

  /// Handed to a coding agent in a genuinely new session.
  handoff;

  static ClosureKind? fromName(String? name) =>
      name == null ? null : ClosureKind.values.asNameMap()[name];
}

/// One capture leaving the desk, for good.
///
/// **The durable record of finished work, and the reason this feature has a
/// store of its own.** `recordings.json` holds `isProcessedByUser` — a single
/// bit of *state*, rewritten wholesale on every mutation and dropped entirely
/// when the capture is deleted. Neither property survives the question this
/// answers: how much did I actually get through last Tuesday. A deletion must
/// not be able to rewrite the past.
class ClosureEvent {
  const ClosureEvent({
    required this.recordingId,
    required this.at,
    required this.kind,
    required this.type,
    this.projectId,
    this.projectName,
  });

  /// Which capture. Also the deduplication key: a capture closes once, ever.
  final String recordingId;

  /// When it closed, in local time — the instant the work became a fact, and
  /// what the day is counted by. Same rule as `FocusSession.completedAt`.
  final DateTime at;

  final ClosureKind kind;
  final CaptureType type;

  /// The capture's project, denormalised exactly as `FocusSession` does it: the
  /// id groups, the name is what a panel can still show after the project has
  /// been renamed or deleted. Resolving the name at read time would let
  /// deleting a project erase the work done under it.
  final String? projectId;
  final String? projectName;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'recordingId': recordingId,
    'at': at.toIso8601String(),
    'kind': kind.name,
    'type': type.name,
    if (projectId != null) 'projectId': projectId,
    if (projectName != null) 'projectName': projectName,
  };

  /// Null when the row cannot be trusted, so the caller can skip exactly that
  /// line. A torn final line after a kill mid-append must cost one event, never
  /// the file — the contract `FocusSession.fromJson` follows.
  static ClosureEvent? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final Object? recordingId = json['recordingId'];
    final Object? at = json['at'];
    if (recordingId is! String || recordingId.isEmpty || at is! String) {
      return null;
    }
    final DateTime? parsed = DateTime.tryParse(at);
    if (parsed == null) return null;
    final Object? kind = json['kind'];
    final ClosureKind? resolved = ClosureKind.fromName(
      kind is String ? kind : null,
    );
    if (resolved == null) return null;
    final Object? type = json['type'];
    final Object? projectId = json['projectId'];
    final Object? projectName = json['projectName'];
    return ClosureEvent(
      recordingId: recordingId,
      // `toIso8601String()` on a local `DateTime` emits no offset, so this is a
      // wall-clock-preserving read. `toLocal()` is for rows that do carry one.
      at: parsed.toLocal(),
      kind: resolved,
      // Unlike the kind, an unknown capture type degrades — this mirrors
      // `CaptureType.fromName`, and getting the icon wrong is not a lie about
      // what happened.
      type: CaptureType.fromName(type is String ? type : null),
      projectId: projectId is String && projectId.trim().isNotEmpty
          ? projectId
          : null,
      projectName: projectName is String && projectName.trim().isNotEmpty
          ? projectName
          : null,
    );
  }
}

/// Where closures are written down.
///
/// A seam for the same reason as `FocusSessionLog`: the real implementation
/// touches the user's disk, and the pure-Dart suite must be able to close a
/// capture without one. The default records nothing, so a host that never wires
/// it behaves exactly as the app did before this existed.
abstract interface class ClosureLog {
  Future<List<ClosureEvent>> load();

  /// Throws on failure. The caller swallows it — see `RecordingsController`.
  Future<void> append(ClosureEvent event);
}

class NoopClosureLog implements ClosureLog {
  const NoopClosureLog();

  @override
  Future<List<ClosureEvent>> load() async => const <ClosureEvent>[];

  @override
  Future<void> append(ClosureEvent event) async {}
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `flutter test test/momentum_closure_test.dart`
Expected: PASS, 7 tests

- [ ] **Step 5: Run the full gate and commit**

```bash
flutter analyze && flutter test
git add lib/features/momentum/domain/closure_event.dart test/momentum_closure_test.dart
git commit -m "feat(momentum): add ClosureEvent and the closure log seam"
```

---

### Task 2: `FileClosureLog`

**Files:**
- Create: `lib/features/momentum/data/file_closure_log.dart`
- Test: extend `test/momentum_closure_test.dart`

**Interfaces:**
- Consumes: `ClosureEvent`, `ClosureLog` (Task 1)
- Produces: `class FileClosureLog implements ClosureLog` with `const FileClosureLog()`, writing `closures.jsonl` in the app documents `recordings/` subfolder

**Note for the implementer:** this class touches the real filesystem via `path_provider`, so its test needs `TestWidgetsFlutterBinding` and a mocked documents directory. The existing suite has no test for `FileFocusSessionLog` for exactly this reason. Rather than introduce that machinery, test the **parsing loop** by extracting it as a static function and testing it directly — that is where every bug in this class lives.

- [ ] **Step 1: Write the failing test**

Append to `test/momentum_closure_test.dart` (inside `main()`):

```dart
  group('FileClosureLog.parse', () {
    test('reads one event per line', () {
      final String raw = <String>[
        jsonEncode(<String, dynamic>{
          'recordingId': 'a',
          'at': DateTime(2026, 8, 9).toIso8601String(),
          'kind': 'review',
          'type': 'text',
        }),
        jsonEncode(<String, dynamic>{
          'recordingId': 'b',
          'at': DateTime(2026, 8, 9).toIso8601String(),
          'kind': 'route',
          'type': 'text',
        }),
      ].join('\n');

      expect(FileClosureLog.parse(raw).length, 2);
    });

    test('a torn final line costs one event, never the file', () {
      final String raw =
          '${jsonEncode(<String, dynamic>{
            'recordingId': 'a',
            'at': DateTime(2026, 8, 9).toIso8601String(),
            'kind': 'review',
            'type': 'text',
          })}\n{"recordingId":"b","at":';

      final List<ClosureEvent> events = FileClosureLog.parse(raw);
      expect(events.length, 1);
      expect(events.single.recordingId, 'a');
    });

    test('blank lines are skipped', () {
      expect(FileClosureLog.parse('\n\n  \n'), isEmpty);
    });
  });
```

Add `import 'dart:convert';` and the `file_closure_log.dart` import at the top of the file.

- [ ] **Step 2: Run the test to verify it fails**

Run: `flutter test test/momentum_closure_test.dart`
Expected: FAIL — `Target of URI doesn't exist` for `file_closure_log.dart`

- [ ] **Step 3: Write the implementation**

Create `lib/features/momentum/data/file_closure_log.dart`:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../domain/closure_event.dart';

/// Closed captures, one JSON object per line in `closures.jsonl`.
///
/// **Appended, never rewritten** — the third store in this repo to break the
/// house style, alongside `revisions.jsonl` and `focus-sessions.jsonl`, and for
/// the same reason. Every other store rewrites its whole contents on each
/// change, which is precisely the shape that once let a single bad read destroy
/// the recordings index. A tally of work already finished is the only copy of
/// that fact, so the file must not be capable of being written wrong in one go.
///
/// This is also why the count is not derived from `recordings.json`. That index
/// is rewritten wholesale and *shrinks* on `deleteRecording`, so a history read
/// from it would be silently rewritten by a deletion.
///
/// Not capped, unlike `logs.json`. One closure is one short line, and trimming
/// it would throw away exactly the months worth looking back at.
class FileClosureLog implements ClosureLog {
  const FileClosureLog();

  /// The parsing loop, exposed so it can be tested without a filesystem or a
  /// Flutter binding. Every bug this class can have lives in here.
  static List<ClosureEvent> parse(String raw) {
    final List<ClosureEvent> events = <ClosureEvent>[];
    for (final String line in const LineSplitter().convert(raw)) {
      if (line.trim().isEmpty) continue;
      try {
        final ClosureEvent? event = ClosureEvent.fromJson(
          jsonDecode(line) as Object?,
        );
        if (event != null) events.add(event);
      } catch (_) {
        // A torn last line from a kill mid-append, or a row from a newer build.
        // Skip it; every other closure in the file is still good.
        continue;
      }
    }
    return events;
  }

  @override
  Future<List<ClosureEvent>> load() async {
    final File file = await _file();
    if (!await file.exists()) return const <ClosureEvent>[];
    // Deliberately *not* caught here: the controller has to be able to tell
    // "you have closed nothing" from "the file could not be read", and it can
    // only do that if a failure reaches it. Same rule as `_indexUnreadable`.
    return parse(await file.readAsString());
  }

  @override
  Future<void> append(ClosureEvent event) async {
    final File file = await _file();
    await file.writeAsString(
      '${jsonEncode(event.toJson())}\n',
      mode: FileMode.writeOnlyAppend,
      // Flushed for the same reason the session log is: the moment after
      // finishing something is exactly when a laptop gets closed.
      flush: true,
    );
  }

  Future<File> _file() async {
    final Directory appDirectory = await getApplicationDocumentsDirectory();
    // Alongside the other stores rather than in a folder of its own, which is
    // what keeps a backup a single directory to copy.
    final Directory directory = Directory(
      p.join(appDirectory.path, 'recordings'),
    );
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return File(p.join(directory.path, 'closures.jsonl'));
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `flutter test test/momentum_closure_test.dart`
Expected: PASS, 10 tests

- [ ] **Step 5: Run the full gate and commit**

```bash
flutter analyze && flutter test
git add lib/features/momentum/data/file_closure_log.dart test/momentum_closure_test.dart
git commit -m "feat(momentum): add the append-only closures.jsonl store"
```

---

### Task 3: Pace, target and the daily tally

**Files:**
- Create: `lib/features/momentum/domain/momentum_snapshot.dart`
- Test: `test/momentum_pace_test.dart`

**Interfaces:**
- Consumes: `ClosureEvent` (Task 1), `focusDayOf` from `lib/features/timer/domain/focus_session.dart`
- Produces: `class DayClosures {DateTime day; int closures;}`, `List<DayClosures> closuresByDay(List<ClosureEvent>)`, `double paceOf(List<ClosureEvent> events, DateTime now)`, `int targetFrom(double pace, int activeDays)`, `int activeDaysIn(List<ClosureEvent> events, DateTime now)`, `class MomentumSnapshot`

**Design notes the implementer must not "improve":**
- `focusDayOf` and `columnsFor` are **imported from the timer's domain, not reimplemented**. `columnsFor` is pure integer arithmetic specifically because deriving column counts from `last.difference(start).inDays` truncates an hour away across a DST transition and drops a whole day — in Europe/Warsaw that removed *today's* cell five Mondays a year.
- Pace uses the median across **active** days (days with ≥1 closure), not calendar days. A weekend must not drag the median to zero, because a target of zero cannot be missed and therefore says nothing.
- The floor of 1 is not a guard, it is the feature: a fresh install and a return after a fortnight both meet a target of 1 — a guaranteed win on the first day back, instead of the target of 5 that was current when the user fell off.

- [ ] **Step 1: Write the failing tests**

Create `test/momentum_pace_test.dart`:

```dart
import 'package:augustyniak_capture/features/momentum/domain/closure_event.dart';
import 'package:augustyniak_capture/features/momentum/domain/momentum_snapshot.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:test/test.dart';

ClosureEvent _at(DateTime when) => ClosureEvent(
  recordingId: '${when.microsecondsSinceEpoch}',
  at: when,
  kind: ClosureKind.review,
  type: CaptureType.text,
);

List<ClosureEvent> _closures(DateTime day, int count) =>
    <ClosureEvent>[for (int i = 0; i < count; i++) _at(day.add(Duration(minutes: i)))];

void main() {
  group('closuresByDay', () {
    test('groups by local day, newest first', () {
      final List<DayClosures> days = closuresByDay(<ClosureEvent>[
        ..._closures(DateTime(2026, 8, 7, 10), 2),
        ..._closures(DateTime(2026, 8, 9, 10), 3),
      ]);

      expect(days.first.day, DateTime(2026, 8, 9));
      expect(days.first.closures, 3);
      expect(days.last.day, DateTime(2026, 8, 7));
      expect(days.last.closures, 2);
    });

    test('a capture closed at 23:50 and one at 00:30 land on different days', () {
      final List<DayClosures> days = closuresByDay(<ClosureEvent>[
        _at(DateTime(2026, 8, 8, 23, 50)),
        _at(DateTime(2026, 8, 9, 0, 30)),
      ]);

      expect(days.length, 2);
    });

    test('does not invent empty days', () {
      final List<DayClosures> days = closuresByDay(<ClosureEvent>[
        _at(DateTime(2026, 8, 1, 10)),
        _at(DateTime(2026, 8, 9, 10)),
      ]);

      expect(days.length, 2);
    });
  });

  group('paceOf', () {
    final DateTime now = DateTime(2026, 8, 9, 18);

    test('is the median across active days, ignoring days with none', () {
      // 5, 1, 3 on three active days within the window; four idle days between.
      final List<ClosureEvent> events = <ClosureEvent>[
        ..._closures(DateTime(2026, 8, 3, 10), 5),
        ..._closures(DateTime(2026, 8, 6, 10), 1),
        ..._closures(DateTime(2026, 8, 9, 10), 3),
      ];

      // Median of [1, 3, 5] is 3 — not the mean of 9/7 days.
      expect(paceOf(events, now), 3);
    });

    test('averages the middle two on an even number of active days', () {
      final List<ClosureEvent> events = <ClosureEvent>[
        ..._closures(DateTime(2026, 8, 6, 10), 2),
        ..._closures(DateTime(2026, 8, 9, 10), 5),
      ];

      expect(paceOf(events, now), 3.5);
    });

    test('ignores closures older than the 14-day window', () {
      final List<ClosureEvent> events = <ClosureEvent>[
        ..._closures(DateTime(2026, 6, 1, 10), 40),
        ..._closures(DateTime(2026, 8, 9, 10), 2),
      ];

      expect(paceOf(events, now), 2);
    });

    test('is zero with no closures at all', () {
      expect(paceOf(const <ClosureEvent>[], now), 0);
    });
  });

  group('targetFrom', () {
    test('floors the pace', () {
      expect(targetFrom(3.8, 10), 3);
    });

    test('never drops below one, however low the pace', () {
      expect(targetFrom(0.2, 10), 1);
      expect(targetFrom(0, 10), 1);
    });

    test('is one while fewer than three active days exist', () {
      // A fresh install and a return after a fortnight both get a guaranteed
      // win on the first day back, rather than the target that was current
      // when the user fell off.
      expect(targetFrom(9, 2), 1);
      expect(targetFrom(9, 3), 9);
    });
  });

  group('activeDaysIn', () {
    test('counts distinct days with at least one closure inside the window', () {
      final DateTime now = DateTime(2026, 8, 9, 18);
      final List<ClosureEvent> events = <ClosureEvent>[
        ..._closures(DateTime(2026, 8, 8, 10), 3),
        ..._closures(DateTime(2026, 8, 9, 10), 1),
        ..._closures(DateTime(2026, 6, 1, 10), 9),
      ];

      expect(activeDaysIn(events, now), 2);
    });
  });

  group('daylight saving', () {
    test('the window is calendar arithmetic and survives a DST boundary', () {
      // Europe/Warsaw springs forward on 2026-03-29. A window computed with
      // Duration loses an hour here and drops a whole day off the far end.
      final DateTime now = DateTime(2026, 3, 30, 12);
      final List<ClosureEvent> events = _closures(DateTime(2026, 3, 17, 12), 4);

      // 2026-03-17 is exactly 13 days before 2026-03-30 — inside a 14-day
      // window, and it must stay inside one.
      expect(paceOf(events, now), 4);
    });
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/momentum_pace_test.dart`
Expected: FAIL — `Target of URI doesn't exist: '.../momentum_snapshot.dart'`

- [ ] **Step 3: Write the implementation**

Create `lib/features/momentum/domain/momentum_snapshot.dart`:

```dart
import '../../timer/domain/focus_session.dart' show focusDayOf;
import 'closure_event.dart';

/// What one day amounts to: how many captures left the desk.
class DayClosures {
  const DayClosures({required this.day, required this.closures});

  /// Local midnight of the day being counted.
  final DateTime day;
  final int closures;

  bool get isEmpty => closures == 0;
}

/// How many calendar days the pace looks back over.
const int paceWindowDays = 14;

/// Below this many active days the target is pinned to 1 — see [targetFrom].
const int paceConfidenceDays = 3;

/// Closures grouped into days, newest first.
///
/// Days with nothing in them are **not** invented here: this reports what
/// happened, and a caller that wants an unbroken calendar strip fills the gaps
/// itself, where it knows how many days it means to show. Same contract as
/// `tallyByDay` in the timer's domain.
List<DayClosures> closuresByDay(List<ClosureEvent> events) {
  final Map<DateTime, int> byDay = <DateTime, int>{};
  for (final ClosureEvent event in events) {
    final DateTime day = focusDayOf(event.at);
    byDay[day] = (byDay[day] ?? 0) + 1;
  }

  final List<DateTime> days = byDay.keys.toList()
    ..sort((DateTime a, DateTime b) => b.compareTo(a));
  return <DayClosures>[
    for (final DateTime day in days)
      DayClosures(day: day, closures: byDay[day]!),
  ];
}

/// Local midnight [days] days before [now], by calendar arithmetic.
///
/// `DateTime(y, m, d - n)` and never `subtract(Duration(days: n))`: a day is not
/// always 24 hours, and across a spring-forward transition the `Duration` form
/// lands an hour early — enough to move the boundary onto the previous day and
/// silently drop it from the window.
DateTime _windowStart(DateTime now, int days) {
  final DateTime local = now.toLocal();
  return DateTime(local.year, local.month, local.day - days + 1);
}

/// Distinct days inside the pace window that saw at least one closure.
int activeDaysIn(List<ClosureEvent> events, DateTime now) {
  final DateTime start = _windowStart(now, paceWindowDays);
  final Set<DateTime> days = <DateTime>{
    for (final ClosureEvent event in events)
      if (!focusDayOf(event.at).isBefore(start)) focusDayOf(event.at),
  };
  return days.length;
}

/// The median number of closures across **active** days in the last
/// [paceWindowDays] calendar days.
///
/// Active days, not calendar days. A weekend or a week off must not drag the
/// median to zero, because a target of zero is a target that cannot be missed
/// and therefore says nothing about whether the day went well.
///
/// A median rather than a mean because one exceptional afternoon — a queue
/// cleared before a holiday — should not raise the bar for the fortnight after
/// it.
double paceOf(List<ClosureEvent> events, DateTime now) {
  final DateTime start = _windowStart(now, paceWindowDays);
  final Map<DateTime, int> byDay = <DateTime, int>{};
  for (final ClosureEvent event in events) {
    final DateTime day = focusDayOf(event.at);
    if (day.isBefore(start)) continue;
    byDay[day] = (byDay[day] ?? 0) + 1;
  }
  if (byDay.isEmpty) return 0;

  final List<int> counts = byDay.values.toList()..sort();
  final int middle = counts.length ~/ 2;
  if (counts.length.isOdd) return counts[middle].toDouble();
  return (counts[middle - 1] + counts[middle]) / 2;
}

/// Today's target: the floor of the pace, never below 1.
///
/// **The floor of 1 is the feature, not a guard.** A fresh install and a return
/// after a fortnight away both meet a target of 1 — a guaranteed win on the
/// first day back, rather than the target of five that was current when the
/// user fell off. That is the endowed-progress effect: a card with two stamps
/// already on it is completed more often than an empty one.
int targetFrom(double pace, int activeDays) {
  if (activeDays < paceConfidenceDays) return 1;
  final int floored = pace.floor();
  return floored < 1 ? 1 : floored;
}

/// Everything the panel and the card read, in one value.
///
/// **Derived on read, never stored.** A running app crosses midnight, and a
/// persisted "today's target" would be yesterday's by morning with nothing to
/// trigger a correction. Same rule as `FocusTimerController.today`.
class MomentumSnapshot {
  const MomentumSnapshot({
    required this.today,
    required this.target,
    required this.pace,
    required this.previousPace,
    required this.days,
  });

  /// How many captures closed today.
  final int today;

  /// What today has to reach for the day to count.
  final int target;

  /// The current pace, and the pace as of a week ago — the pair is what lets
  /// the card say `↑ from 2.8` rather than reporting a number with no baseline.
  final double pace;
  final double previousPace;

  /// The window the panel charts, newest first, gaps not filled.
  final List<DayClosures> days;

  bool get metTarget => today >= target;

  /// Null when there is no meaningful comparison yet, so the UI can omit the
  /// arrow rather than draw a misleading flat one.
  bool? get rising {
    if (previousPace == 0 && pace == 0) return null;
    if (pace == previousPace) return null;
    return pace > previousPace;
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `flutter test test/momentum_pace_test.dart`
Expected: PASS, 12 tests

- [ ] **Step 5: Run the full gate and commit**

```bash
flutter analyze && flutter test
git add lib/features/momentum/domain/momentum_snapshot.dart test/momentum_pace_test.dart
git commit -m "feat(momentum): derive the daily target from the user's own pace"
```

---

### Task 4: Record closures from the controller funnel

**Files:**
- Modify: `lib/features/recordings/presentation/recordings_controller.dart`
- Test: `test/momentum_controller_test.dart` (new file, controller-level tests)

**Interfaces:**
- Consumes: `ClosureEvent`, `ClosureKind`, `ClosureLog`, `NoopClosureLog` (Task 1)
- Produces: `RecordingsController({… ClosureLog closureLog = const NoopClosureLog()})`, a `ClosureKind closure` parameter on the private `_update`, and `Future<void> loadClosures()` populating the dedup set at startup

**This is the highest-risk task in the plan. Read all of this before editing.**

`isProcessedByUser` is set to `true` in **three** places today — `toggleProcessed` (~line 1195), `route` (~line 1262) and the agent handoff (~line 1365). Appending at each call site would count one routed capture twice and leave any fourth path silently uncounted. The diff therefore goes inside `_update` (~line 2035), beside `_recordRevisions`, which is the funnel every mutation already passes through.

An optional parameter is safe on `_update` in a way it would not be on `saveAll`: `_update` is private to this class, so no test fake overrides it and none can silently stop matching the signature. (That is exactly why `expectRowCount` is a separate call rather than a `saveAll` parameter — a dozen fakes override `saveAll`.)

- [ ] **Step 1: Extend the shared harness**

`test/support/harness.dart:111` already builds a fully faked, `initialize()`d controller. Add one parameter rather than hand-rolling fakes:

```dart
  ClosureLog closureLog = const NoopClosureLog(),
```

and pass `closureLog: closureLog` into the `RecordingsController(…)` call inside it.

- [ ] **Step 2: Write the failing tests**

Create `test/momentum_controller_test.dart`:

```dart
import 'dart:io';

import 'package:augustyniak_capture/features/momentum/domain/closure_event.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

/// Records what was appended, so a test can assert the count and the kind
/// without a filesystem. Same shape as `_MemoryLogArchive` in the harness.
class _RecordingClosureLog implements ClosureLog {
  final List<ClosureEvent> appended = <ClosureEvent>[];
  List<ClosureEvent> preloaded = const <ClosureEvent>[];

  @override
  Future<List<ClosureEvent>> load() async => preloaded;

  @override
  Future<void> append(ClosureEvent event) async => appended.add(event);
}

/// Fails every append, to prove a broken log never fails a close.
class _FailingClosureLog implements ClosureLog {
  @override
  Future<List<ClosureEvent>> load() async => const <ClosureEvent>[];

  @override
  Future<void> append(ClosureEvent event) async =>
      throw const FileSystemException('disk full');
}

Recording _completed(String id) => Recording(
  id: id,
  path: '/tmp/$id.txt',
  createdAt: DateTime(2026, 8, 9, 10),
  durationMs: 0,
  status: RecordingStatus.completed,
  type: CaptureType.text,
  transcript: 'a thought',
);

void main() {
  late Directory appDir;

  setUp(() {
    appDir = Directory.systemTemp.createTempSync('momentum-test');
    addTearDown(() => appDir.deleteSync(recursive: true));
  });

  test('closing a capture by hand records one review closure', () async {
    final _RecordingClosureLog log = _RecordingClosureLog();
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[_completed('a')],
      closureLog: log,
    );

    await controller.toggleProcessed('a');

    expect(log.appended.length, 1);
    expect(log.appended.single.recordingId, 'a');
    expect(log.appended.single.kind, ClosureKind.review);
    expect(log.appended.single.type, CaptureType.text);
  });

  test('un-closing and re-closing records nothing the second time', () async {
    // A capture closes once, ever — otherwise the count could be farmed by
    // toggling one row rather than by doing any work.
    final _RecordingClosureLog log = _RecordingClosureLog();
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[_completed('a')],
      closureLog: log,
    );

    await controller.toggleProcessed('a'); // closed
    await controller.toggleProcessed('a'); // re-opened
    await controller.toggleProcessed('a'); // closed again

    expect(log.appended.length, 1);
  });

  test('routing records exactly one closure, of kind route', () async {
    // `route()` sets isProcessedByUser itself, so an implementation that
    // appended at each call site would record two events for one delivery.
    final _RecordingClosureLog log = _RecordingClosureLog();
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[_completed('a')],
      captureRouter: RecordingCaptureRouter(),
      closureLog: log,
    );

    await controller.route('a');

    expect(log.appended.length, 1);
    expect(log.appended.single.kind, ClosureKind.route);
  });

  test('a failing closure log never fails the close', () async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[_completed('a')],
      closureLog: _FailingClosureLog(),
    );

    await controller.toggleProcessed('a');

    expect(controller.recordings.single.isProcessedByUser, isTrue);
    expect(controller.error, isNull);
  });

  test('a capture closed in an earlier session is not counted again', () async {
    final _RecordingClosureLog log = _RecordingClosureLog()
      ..preloaded = <ClosureEvent>[
        ClosureEvent(
          recordingId: 'a',
          at: DateTime(2026, 8, 1),
          kind: ClosureKind.review,
          type: CaptureType.text,
        ),
      ];
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[_completed('a')],
      closureLog: log,
    );
    await controller.loadClosures();

    await controller.toggleProcessed('a'); // re-opened
    await controller.toggleProcessed('a'); // closed again

    expect(log.appended, isEmpty);
  });
}
```

**`RecordingCaptureRouter` in the routing test** is whichever recording fake the existing routing tests already use — check `test/routing_test.dart` (or whichever file exercises `controller.route`) and reuse it verbatim rather than writing a third one. If the seeded capture needs a `projectId` for routing to be permitted, seed one and assert `log.appended.single.projectId` alongside the kind.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `flutter test test/momentum_controller_test.dart`
Expected: FAIL — the `closureLog` named parameter does not exist

- [ ] **Step 4: Add the seam and the dedup set**

In `RecordingsController`, add to the constructor parameter list and the initialiser list:

```dart
    ClosureLog closureLog = const NoopClosureLog(),
    …
  }) : _closureLog = closureLog,
```

Add the fields:

```dart
  final ClosureLog _closureLog;

  /// Ids that have already been counted as closed, so a capture closes once and
  /// only once however many times it is re-ticked or re-delivered.
  ///
  /// In memory and transient, the same class of fact as `_enrichingIds` and
  /// `_postersInFlight`: nothing about it survives a restart, and the log on
  /// disk is what repopulates it — see [loadClosures].
  final Set<String> _closedIds = <String>{};
```

Add the startup read, called by the shell after `initialize`:

```dart
  /// Populates the dedup set from the log.
  ///
  /// Called by the shell after `initialize`, never from inside it — the same
  /// rule `recoverOrphans` follows, and for the same reason: it is IO an
  /// in-memory repository fake cannot stand in for, and running it from
  /// `initialize` made every widget test reach the developer's real disk.
  Future<void> loadClosures() async {
    try {
      for (final ClosureEvent event in await _closureLog.load()) {
        _closedIds.add(event.recordingId);
      }
    } catch (exception) {
      // Best-effort: an unreadable log costs deduplication accuracy for this
      // session, never a close. `MomentumController` reports the unreadable
      // state to the user; this side only needs to keep working.
      _logSink.log(
        'Closure history not read: $exception',
        level: LogLevel.warn,
      );
    }
  }
```

- [ ] **Step 5: Add the diff inside `_update`**

Change the signature (~line 2035):

```dart
  Future<void> _update(
    String id,
    Recording Function(Recording) transform, {
    RevisionSource source = RevisionSource.processor,
    ClosureKind closure = ClosureKind.review,
  }) async {
```

Immediately after the existing `await _recordRevisions(before, _recordings[index], source);` line, add:

```dart
    await _recordClosure(before, _recordings[index], closure);
```

Then add the method beside `_recordRevisions`:

```dart
  /// Appends one [ClosureEvent] the first time a capture becomes closed.
  ///
  /// **In `_update` rather than at the call sites, and that is the whole
  /// point.** Three paths set `isProcessedByUser` today — `toggleProcessed`,
  /// `route` and the agent handoff, the latter two because closing the item is
  /// the *consequence* of delivering it rather than a second chore. Appending
  /// at each of them would count one routed capture twice, and would leave the
  /// fourth path uncounted the day somebody adds one. A funnel cannot be
  /// bypassed by adding a new setter, which is the same argument that put
  /// `_recordRevisions` here.
  ///
  /// **A capture closes once, ever.** Re-opening and re-closing appends
  /// nothing, so the count cannot be farmed by toggling a row.
  ///
  /// Best-effort on the [_copyToClipboard] contract: the in-memory set is
  /// updated first, so a failed write leaves this session's deduplication
  /// correct and merely incomplete on disk, rather than wrong in both places.
  Future<void> _recordClosure(
    Recording before,
    Recording after,
    ClosureKind kind,
  ) async {
    if (before.isProcessedByUser || !after.isProcessedByUser) return;
    if (!_closedIds.add(after.id)) return;

    // `_projectById` already exists on this class (a
    // `Project? Function(String)?` callback seam, used at ~line 1398 by the
    // routing path). Reuse it — do not add a projects dependency for a display
    // string. Null is fine: the id still groups, and `tallyByProject` already
    // falls back to `Unnamed project`.
    final String? projectId = after.projectId;
    final Project? project = projectId == null
        ? null
        : _projectById?.call(projectId);
    try {
      await _closureLog.append(
        ClosureEvent(
          recordingId: after.id,
          at: after.processedAt ?? DateTime.now(),
          kind: kind,
          type: after.type,
          projectId: after.projectId,
          projectName: project?.name,
        ),
      );
    } catch (exception) {
      _logSink.log(
        'Closure not written: $exception',
        level: LogLevel.warn,
        recordingId: after.id,
      );
    }
  }
```

- [ ] **Step 6: Pass the kind from the two delivery paths**

In `route` (~line 1262) and the agent handoff (~line 1365), add `closure:` to the existing `_update` call:

```dart
    await _update(
      id,
      (Recording item) => item.copyWith(…),
      closure: ClosureKind.route,      // and ClosureKind.handoff respectively
    );
```

`toggleProcessed` needs no change — `review` is the default.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `flutter test test/momentum_controller_test.dart`
Expected: PASS, 5 tests

- [ ] **Step 8: Prove the tests are not vacuous**

Copy the controller to the scratchpad first — **never `git checkout --` in a dirty tree**, it reverts to `HEAD` and takes every other uncommitted change in the file with it.

```bash
cp lib/features/recordings/presentation/recordings_controller.dart /tmp/rc.bak
```

Then delete the `if (!_closedIds.add(after.id)) return;` line and re-run. The "re-closing records nothing" test must go red. Restore with `cp /tmp/rc.bak lib/features/recordings/presentation/recordings_controller.dart`.

A test written after the fix that has never been seen red is an assumption, not a check.

- [ ] **Step 9: Run the full gate and commit**

```bash
flutter analyze && flutter test
git add lib/features/recordings/presentation/recordings_controller.dart test/momentum_controller_test.dart
git commit -m "feat(momentum): record a closure when a capture leaves the desk"
```

---

### Task 5: `MomentumController`

**Files:**
- Create: `lib/features/momentum/presentation/momentum_controller.dart`
- Test: extend `test/momentum_controller_test.dart`

**Interfaces:**
- Consumes: `ClosureLog` (Task 1), `MomentumSnapshot`/`paceOf`/`targetFrom`/`closuresByDay` (Task 3), `FocusSession` from the timer's domain
- Produces: `MomentumController extends ChangeNotifier` with `MomentumController({required ClosureLog log, FocusSessionsReader? sessions, DateTime Function() clock = DateTime.now})`, `Future<void> initialize()`, `void noteClosure(ClosureEvent)`, `MomentumSnapshot snapshot({int days = 7})`, `bool get historyUnreadable`, `bool get hasClosures`, and `typedef FocusSessionsReader = List<FocusSession> Function()`

- [ ] **Step 1: Write the failing tests**

Append to `test/momentum_controller_test.dart`:

```dart
  group('MomentumController', () {
    test('reports three states, not two', () async {
      // "You have closed nothing" is a positive claim about the user's history
      // and must not be made when the file merely failed to read. Same rule as
      // _indexUnreadable and historyUnreadable.
      final MomentumController failing = MomentumController(
        log: _ThrowingClosureLog(),
      );
      await failing.initialize();

      expect(failing.historyUnreadable, isTrue);
      expect(failing.hasClosures, isFalse);

      final MomentumController empty = MomentumController(
        log: _RecordingClosureLog(),
      );
      await empty.initialize();

      expect(empty.historyUnreadable, isFalse);
      expect(empty.hasClosures, isFalse);
    });

    test('snapshot counts today against a target from the pace', () async {
      // Seed 5, 1, 3 across three active days, then two closures today.
      // expect(snapshot.target, 3);
      // expect(snapshot.today, 2);
      // expect(snapshot.metTarget, isFalse);
    });

    test('noteClosure updates the snapshot without a reload', () async {
      // The controller is told about a closure by the shell rather than
      // re-reading the file, so the counter moves in the same frame the row
      // leaves the queue.
    });

    test('the window keeps empty days so a gap is visible', () async {
      // recentDays-style filling: seven entries for a seven-day window even
      // when only two of them saw anything. "Three a day" and "three once a
      // week" are the same tallies and a very different working week.
    });
  });
```

Add a `_ThrowingClosureLog` whose `load()` throws.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/momentum_controller_test.dart`
Expected: FAIL — `MomentumController` undefined

- [ ] **Step 3: Write the implementation**

Create `lib/features/momentum/presentation/momentum_controller.dart`:

```dart
import 'package:flutter/foundation.dart';

import '../../timer/domain/focus_session.dart';
import '../domain/closure_event.dart';
import '../domain/momentum_snapshot.dart';

/// Reads the timer's already-loaded sessions.
///
/// A callback rather than a second `FocusSessionLog`, for the same reason
/// `FocusProjectResolver` is one: it avoids a second read of the same file, a
/// session that just finished is visible immediately, and the dependency is on
/// the `FocusSession` type alone. **This feature never writes to
/// `focus-sessions.jsonl`** — `_record()` being called from `_finish()` and
/// nowhere else is the only reason "a pomodoro" means exactly one thing.
typedef FocusSessionsReader = List<FocusSession> Function();

class MomentumController extends ChangeNotifier {
  MomentumController({
    required ClosureLog log,
    FocusSessionsReader? sessions,
    DateTime Function() clock = DateTime.now,
  }) : _log = log,
       _sessions = sessions,
       _clock = clock;

  final ClosureLog _log;
  final FocusSessionsReader? _sessions;

  /// A seam, like `FocusTimerController`'s: the target reads the last fourteen
  /// days, so a test must be able to substitute a date rather than wait for one.
  final DateTime Function() _clock;

  List<ClosureEvent> _events = const <ClosureEvent>[];
  bool _historyUnreadable = false;

  /// True when the log could not be read. Distinct from "nothing closed yet",
  /// because the second is a claim about the user's history that must not be
  /// made on the strength of a failed read.
  bool get historyUnreadable => _historyUnreadable;

  bool get hasClosures => _events.isNotEmpty;

  Future<void> initialize() async {
    try {
      _events = await _log.load();
      _historyUnreadable = false;
    } catch (_) {
      _events = const <ClosureEvent>[];
      _historyUnreadable = true;
    }
    notifyListeners();
  }

  /// Told about a closure rather than re-reading the file, so the counter moves
  /// in the same frame the row leaves the queue.
  void noteClosure(ClosureEvent event) {
    _events = <ClosureEvent>[..._events, event];
    notifyListeners();
  }

  /// Focus sessions finished today, for the card's second line. Zero when the
  /// host wires no reader — a valid configuration, not an error.
  int get sessionsToday {
    final FocusSessionsReader? reader = _sessions;
    if (reader == null) return 0;
    final DateTime today = focusDayOf(_clock());
    return reader()
        .where((FocusSession s) => focusDayOf(s.completedAt) == today)
        .length;
  }

  /// Everything the panel and the card read, in one derived value.
  ///
  /// The window **keeps its empty days**, unlike [closuresByDay]: "three a day"
  /// and "three once a week" are the same list of tallies and a very different
  /// working week. Same decision as `FocusTimerController.recentDays`.
  MomentumSnapshot snapshot({int days = 7}) {
    final DateTime now = _clock();
    final DateTime today = focusDayOf(now);

    final Map<DateTime, int> byDay = <DateTime, int>{
      for (final DayClosures entry in closuresByDay(_events))
        entry.day: entry.closures,
    };

    final List<DayClosures> window = <DayClosures>[
      for (int i = 0; i < days; i++)
        // Calendar arithmetic, never `subtract(Duration(days: i))`: a day is
        // not always 24 hours, and the Duration form drops a column across a
        // spring-forward transition.
        if (true)
          () {
            final DateTime day = DateTime(
              today.year,
              today.month,
              today.day - i,
            );
            return DayClosures(day: day, closures: byDay[day] ?? 0);
          }(),
    ];

    // A week earlier, so the card can say `↑ from 2.8` rather than reporting a
    // number against no baseline.
    final DateTime lastWeek = DateTime(
      today.year,
      today.month,
      today.day - 7,
    );

    return MomentumSnapshot(
      today: byDay[today] ?? 0,
      target: targetFrom(paceOf(_events, now), activeDaysIn(_events, now)),
      pace: paceOf(_events, now),
      previousPace: paceOf(_events, lastWeek),
      days: window,
    );
  }
}
```

**Note:** the `if (true) …` immediately-invoked closure inside the collection literal is awkward. Replace it with a plain loop building the list before the `return` — the comment about calendar arithmetic must survive the rewrite.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `flutter test test/momentum_controller_test.dart`
Expected: PASS

- [ ] **Step 5: Run the full gate and commit**

```bash
flutter analyze && flutter test
git add lib/features/momentum/presentation/momentum_controller.dart test/momentum_controller_test.dart
git commit -m "feat(momentum): derive the snapshot the panel and card read"
```

---

### Task 6: Cue sounds

**Files:**
- Create: `lib/features/momentum/domain/cue_player.dart`, `lib/features/momentum/data/asset_cue_player.dart`, `assets/sounds/close.wav`, `assets/sounds/day.wav`
- Modify: `lib/features/settings/domain/app_settings.dart`
- Test: extend `test/settings_test.dart`

**Interfaces:**
- Produces: `enum Cue { closed, dayClosed }` with `String get asset`, `abstract interface class CuePlayer { Future<void> play(Cue cue); }`, `class NoopCuePlayer implements CuePlayer`, `class AssetCuePlayer implements CuePlayer`, `AppSettings.cueSounds` getter + `hasCueSoundsPreference`

- [ ] **Step 1: Generate the two clips**

Decaying sines, mono 22.05 kHz, like the three existing alarms. **Peaked at −18 dBFS, not the alarms' −3** — an alarm exists to pull the user out of work, a cue exists to be barely noticed. A cue that makes someone flinch on every tap gets the *system* volume muted, taking the session alarm with it.

```bash
# close.wav — one tone, ~80 ms
ffmpeg -f lavfi -i "sine=frequency=880:duration=0.08:sample_rate=22050" \
  -af "afade=t=out:st=0.02:d=0.06,volume=-18dB" -ac 1 assets/sounds/close.wav

# day.wav — two tones, falling interval, ~260 ms
ffmpeg -f lavfi -i "sine=frequency=880:duration=0.12:sample_rate=22050" \
  -f lavfi -i "sine=frequency=587:duration=0.14:sample_rate=22050" \
  -filter_complex "[0]afade=t=out:st=0.06:d=0.06[a];[1]afade=t=out:st=0.04:d=0.10[b];[a][b]concat=n=2:v=0:a=1,volume=-18dB" \
  -ac 1 assets/sounds/day.wav
```

Verify both exist and are under 30 kB: `ls -la assets/sounds/`. Confirm `pubspec.yaml` globs `assets/sounds/` (it already ships three clips from there); add the entry only if it names files individually.

- [ ] **Step 2: Write the failing tests**

Append to `test/settings_test.dart`:

```dart
  group('cue sounds', () {
    test('absent from JSON means the shipped default, and the key is omitted', () {
      // Absent = never configured, so a later build can still ship a better
      // default to everyone who has not chosen. Same three-state private
      // nullable as `shortcuts` and `enrichmentInstructions`.
      const AppSettings settings = AppSettings();

      expect(settings.cueSounds, isTrue);
      expect(settings.hasCueSoundsPreference, isFalse);
      expect(settings.toJson().containsKey('cueSounds'), isFalse);
    });

    test('an explicit false survives a round trip', () {
      final AppSettings off = const AppSettings().copyWith(cueSounds: false);

      expect(off.hasCueSoundsPreference, isTrue);
      expect(off.toJson()['cueSounds'], isFalse);
      expect(AppSettings.fromJson(off.toJson()).cueSounds, isFalse);
    });

    test('an unrelated save does not promote an untouched install', () {
      // copyWith must fall back to the raw field, not the getter — otherwise
      // changing the theme would silently record a cue preference nobody set.
      final AppSettings themed = const AppSettings().copyWith(
        themeMode: AppThemeMode.dark,
      );

      expect(themed.hasCueSoundsPreference, isFalse);
    });
  });
```

Also create `test/momentum_cue_test.dart`:

```dart
import 'package:augustyniak_capture/features/momentum/domain/cue_player.dart';
import 'package:test/test.dart';

void main() {
  test('each cue names a vendored asset', () {
    expect(Cue.closed.asset, 'sounds/close.wav');
    expect(Cue.dayClosed.asset, 'sounds/day.wav');
  });
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `flutter test test/settings_test.dart test/momentum_cue_test.dart`
Expected: FAIL — `cueSounds` and `Cue` undefined

- [ ] **Step 4: Write `cue_player.dart`**

```dart
/// A short confirmation sound. Not an alarm.
///
/// The clips are **vendored** under `assets/sounds/` for the reason the fonts
/// and the alarms are: the app is offline-first, and a confirmation that only
/// plays once the device has network is not a confirmation.
enum Cue {
  /// One capture left the desk.
  closed,

  /// Today reached its target — at most once a day.
  dayClosed;

  String get asset => switch (this) {
    Cue.closed => 'sounds/close.wav',
    Cue.dayClosed => 'sounds/day.wav',
  };
}

/// Plays confirmation cues.
///
/// A seam of the `AlarmPlayer` shape: the interface lives in `domain/` so the
/// pure-Dart suite can assert *which* cue was requested with no audio device
/// present. [NoopCuePlayer] is the default, so a host that wires nothing
/// behaves exactly as the app did before this existed.
abstract interface class CuePlayer {
  Future<void> play(Cue cue);
}

class NoopCuePlayer implements CuePlayer {
  const NoopCuePlayer();

  @override
  Future<void> play(Cue cue) async {}
}
```

- [ ] **Step 5: Write `asset_cue_player.dart`**

```dart
import 'package:audioplayers/audioplayers.dart';

import '../domain/cue_player.dart';

/// The real [CuePlayer]: a bundled clip through `audioplayers`.
///
/// **Its own [AudioPlayer]**, never the one `RecordingsController` uses for
/// capture playback and never the alarm's — the same rule, for the same reason:
/// confirming a close must not stop a clip that is being reviewed, and it must
/// not silence a session alarm either.
class AssetCuePlayer implements CuePlayer {
  AssetCuePlayer({AudioPlayer? player}) : _player = player ?? AudioPlayer();

  final AudioPlayer _player;

  @override
  Future<void> play(Cue cue) async {
    // Stopped first so closing three rows quickly restarts the cue rather than
    // layering three copies into a rattle.
    await _player.stop();
    await _player.play(AssetSource(cue.asset));
  }
}
```

- [ ] **Step 6: Add `cueSounds` to `AppSettings`**

Follow the `_enrichmentInstructions` pattern exactly. Constructor takes `bool? cueSounds` and assigns `_cueSounds = cueSounds`. Then:

```dart
  final bool? _cueSounds;

  /// **Three-state, like `_shortcuts` and `_enrichmentInstructions`.** Absent =
  /// never configured, so a later build can still ship a different default to
  /// everyone who never chose; present = authoritative, including `false`,
  /// because switching the cues off is a decision that must survive a restart.
  bool get cueSounds => _cueSounds ?? true;

  bool get hasCueSoundsPreference => _cueSounds != null;
```

In `copyWith`, add `bool? cueSounds` and pass `cueSounds: cueSounds ?? _cueSounds` — **the raw field, not the getter**, or any unrelated save would promote an untouched install to a custom one.

In `toJson`, add `if (_cueSounds != null) 'cueSounds': _cueSounds,`.

In `fromJson`, add `cueSounds: json['cueSounds'] is bool ? json['cueSounds'] as bool : null,`.

- [ ] **Step 7: Play the cue from the controller**

`CuePlayer` exists only now, which is why this is here and not in Task 4.

Add to `RecordingsController` a **settable** field, like `transcriptionService` and `audioConfig`, so a Config-tab change reaches the next close without rebuilding anything:

```dart
  /// Settable at runtime from the Config tab. A swap only affects closes that
  /// happen afterwards — the same rule the transcription service follows.
  CuePlayer cuePlayer = const NoopCuePlayer();
```

At the tail of `_recordClosure`, **after** the append and outside its `try`:

```dart
    // Best-effort and last, under the `ClipboardSink` contract: a device that
    // refuses to play costs the sound, never the close. Deliberately not inside
    // the try above — a failed *write* must still make the sound, because the
    // capture did leave the desk either way.
    unawaited(cuePlayer.play(Cue.closed).catchError((Object _) {}));
```

The `dayClosed` cue is **not** played here — the controller does not know today's target. `_QueueTabState` plays it once, in the same branch that first renders `DayClosedCard` (Task 9), guarded by the same `_dayCardDismissed`-style flag so it fires once per day rather than on every rebuild.

Add a test to `test/momentum_controller_test.dart`:

```dart
  test('closing plays the closed cue exactly once', () async {
    final _RecordingCuePlayer cues = _RecordingCuePlayer();
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[_completed('a')],
      closureLog: _RecordingClosureLog(),
    )..cuePlayer = cues;

    await controller.toggleProcessed('a'); // closed
    await controller.toggleProcessed('a'); // re-opened — no cue
    await controller.toggleProcessed('a'); // closed again — already counted

    expect(cues.played, <Cue>[Cue.closed]);
  });
```

with a `_RecordingCuePlayer implements CuePlayer` collecting into `List<Cue> played`.

- [ ] **Step 8: Run the tests to verify they pass**

Run: `flutter test test/settings_test.dart test/momentum_cue_test.dart test/momentum_controller_test.dart`
Expected: PASS

- [ ] **Step 9: Run the full gate and commit**

```bash
flutter analyze && flutter test
git add lib/features/momentum/domain/cue_player.dart lib/features/momentum/data/asset_cue_player.dart assets/sounds/close.wav assets/sounds/day.wav lib/features/settings/domain/app_settings.dart test/settings_test.dart test/momentum_cue_test.dart
git commit -m "feat(momentum): add confirmation cues and the cueSounds preference"
```

---

### Task 7: The `MOMENTUM` panel

**Files:**
- Create: `lib/features/momentum/presentation/momentum_panel.dart`
- Modify: `lib/features/timer/presentation/timer_tab.dart`
- Test: `test/widget/momentum_panel_test.dart`

**Interfaces:**
- Consumes: `MomentumController` (Task 5), `ConsoleCard`, `ConsoleChip`, `SectionHeader`, `ConsoleText`, `Console` from `lib/app/ui_kit.dart`

**Placement and naming — both load-bearing:**
- Mounted in `timer_tab.dart` **above** the existing `SectionHeader(title: 'SESSIONS DONE')`, under its own `SectionHeader(title: 'MOMENTUM')`.
- **Give it a `ValueKey`**, like `_FocusHistory` has. It sits below a conditional `_FinishedPanel` in a keyless `ListView`, so finishing a session inserts children above it and index-based reconciliation would discard the state holding the chosen window.
- The project section's heading is **`CLOSED BY PROJECT`, not `WHERE IT WENT`** — the Timer tab already carries a section under that heading for the session split, and two identical headings describing different things on one screen is a genuine ambiguity.
- **No `const` constructor** on this widget or any private widget in the file. They paint palette colours, and `Console`'s colours are mutable globals so the theme can swap at runtime; a `const` widget keeps painting the old palette after a swap, which no widget test can see.

- [ ] **Step 1: Write the failing tests**

Create `test/widget/momentum_panel_test.dart`:

```dart
import 'package:augustyniak_capture/features/momentum/presentation/momentum_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('an unreadable history is not reported as an empty one', (
    WidgetTester tester,
  ) async {
    // Mount with a controller whose log throws.
    // "You have closed nothing" is a claim about the user's history and must
    // not be made when the file merely failed to read.
    // expect(find.textContaining('could not be read'), findsOneWidget);
    // expect(find.textContaining('Nothing closed yet'), findsNothing);
  });

  testWidgets('an empty history says so plainly', (WidgetTester tester) async {
    // expect(find.textContaining('Nothing closed yet'), findsOneWidget);
  });

  testWidgets('shows today against the target', (WidgetTester tester) async {
    // Seed a snapshot with today: 4, target: 3.
    // expect(find.text('4'), findsOneWidget);
    // expect(find.textContaining('target 3'), findsOneWidget);
  });

  testWidgets('the 30-day window survives a rebuild above it', (
    WidgetTester tester,
  ) async {
    // Tap [30 DAYS], pump a rebuild that inserts a sibling above the panel,
    // and assert the chip is still selected. This is what the ValueKey buys.
  });

  testWidgets('settles — nothing here animates forever', (
    WidgetTester tester,
  ) async {
    // await tester.pumpAndSettle();  // must not time out
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/widget/momentum_panel_test.dart`
Expected: FAIL — `momentum_panel.dart` does not exist

- [ ] **Step 3: Write the panel**

Model it directly on `_FocusHistory` in `timer_tab.dart:435-560` — read that first and mirror its structure so the two read as two measures of one rhythm: the 34 px display figure with a label beside it, the `[7 DAYS] [30 DAYS]` chip row with a right-aligned window total, then the chart, then the project split.

Three states in this order, matching `_FocusHistory` exactly:

```dart
    if (controller.historyUnreadable) {
      return ConsoleCard(
        accent: Console.amber.withValues(alpha: .45),
        child: Text(
          'The closure history could not be read, so this is not a count of '
          'nothing — it is no answer. Closed captures are still being '
          'appended; the Logs tab has the reason.',
          style: ConsoleText.micro.copyWith(height: 1.45),
        ),
      );
    }
    if (!controller.hasClosures) {
      return ConsoleCard(
        child: Text(
          'Nothing closed yet. A capture counts here when it leaves the desk — '
          'ticked off, routed to a project inbox, or handed to an agent.',
          style: ConsoleText.micro.copyWith(height: 1.45),
        ),
      );
    }
```

The target line reads `target N` with a `✓` when met, using `Console.green` when met and `Console.accent` otherwise — matching `ReviewedStrip`'s existing colour rule.

- [ ] **Step 4: Mount it in the Timer tab**

In `timer_tab.dart`, immediately before the existing `SectionHeader(title: 'SESSIONS DONE')` block:

```dart
          SectionHeader(
            title: 'MOMENTUM',
            trailing: momentum.hasClosures ? 'what left the desk' : null,
          ),
          const SizedBox(height: 12),
          MomentumPanel(
            key: const ValueKey<String>('momentum-panel'),
            controller: momentum,
          ),
          const SizedBox(height: 26),
```

`TimerTab` takes a new `required MomentumController momentum` parameter; the shell supplies it in Task 9.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `flutter test test/widget/momentum_panel_test.dart`
Expected: PASS, 5 tests

- [ ] **Step 6: Run the full gate and commit**

```bash
flutter analyze && flutter test
git add lib/features/momentum/presentation/momentum_panel.dart lib/features/timer/presentation/timer_tab.dart test/widget/momentum_panel_test.dart
git commit -m "feat(momentum): add the MOMENTUM panel to the Timer tab"
```

---

### Task 8: Queue feedback — the closing row and the moving counter

**Files:**
- Modify: `lib/features/recordings/presentation/queue_tab.dart`, `lib/features/recordings/presentation/queue_metrics.dart`, `lib/features/recordings/presentation/compact_queue_header.dart`
- Test: extend `test/widget/queue_tab_test.dart` (read it first for the existing harness)

**The hazard this task exists to fix:** with the `DESK` review filter active, a closed capture stops matching `_matchesReview` immediately and vanishes with no animation at all — the work simply evaporates. `_QueueTabState` therefore holds `_closingIds`, and `_matchesReview` treats those as still visible for the duration of the animation.

- [ ] **Step 1: Write the failing tests**

```dart
  testWidgets('a row closed under the DESK filter animates out instead of '
      'vanishing', (WidgetTester tester) async {
    // With ReviewFilter.desk active, tap the done control on a row.
    // Immediately after the tap the row must still be on screen…
    // await tester.pump();
    // expect(find.text('Onboarding'), findsOneWidget);
    // …and gone once the animation completes.
    // await tester.pump(const Duration(milliseconds: 400));
    // expect(find.text('Onboarding'), findsNothing);
  });

  testWidgets('the closing timer is cancelled on dispose', (
    WidgetTester tester,
  ) async {
    // Close a row, then immediately pump a different widget tree.
    // The binding reports a pending timer as a leak if this is wrong.
    // await tester.pumpWidget(Container());
  });

  testWidgets('the queue still settles while a row is closing', (
    WidgetTester tester,
  ) async {
    // await tester.pumpAndSettle();  // must not time out — one-shot only
  });
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/widget/queue_tab_test.dart`
Expected: FAIL — the row disappears on the first pump

- [ ] **Step 3: Add `_closingIds` to `_QueueTabState`**

```dart
  /// Ids closed within the last [_closeAnimation] — kept visible so the row can
  /// animate out instead of vanishing.
  ///
  /// With the DESK filter active a closed capture stops matching immediately,
  /// so without this the work evaporates rather than being seen to leave.
  /// Transient and presentational, which is why it lives here rather than in
  /// the controller — the same class of fact as `_enrichingIds`, one layer up.
  final Set<String> _closingIds = <String>{};
  final List<Timer> _closingTimers = <Timer>[];

  static const Duration _closeAnimation = Duration(milliseconds: 320);

  void _noteClosing(String id) {
    setState(() => _closingIds.add(id));
    _closingTimers.add(
      Timer(_closeAnimation, () {
        if (!mounted) return;
        setState(() => _closingIds.remove(id));
      }),
    );
  }

  @override
  void dispose() {
    // Not optional: a pending timer firing into a disposed State is reported as
    // a leak by the test binding, and the suite fails on the next test rather
    // than on this one.
    for (final Timer timer in _closingTimers) {
      timer.cancel();
    }
    super.dispose();
  }
```

In `_matchesReview`, admit closing ids regardless of the filter:

```dart
    if (_closingIds.contains(item.id)) return true;
```

Wrap the row in a one-shot fade-and-slide keyed by whether it is closing:

```dart
    final bool closing = _closingIds.contains(item.id);
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: closing ? 1 : 0),
      duration: _closeAnimation,
      curve: Curves.easeOutCubic,
      builder: (BuildContext context, double t, Widget? child) => Opacity(
        opacity: 1 - t,
        child: Transform.translate(offset: Offset(12 * t, 0), child: child),
      ),
      child: row,
    );
```

Call `_noteClosing(id)` from the same handler that calls `controller.toggleProcessed(id)` / `controller.route(id)`, **before** awaiting.

- [ ] **Step 4: Animate the counters**

In `queue_metrics.dart`, wrap the `'$reviewed / $total'` text in the same one-shot `TweenAnimationBuilder<double>` the progress bar already uses, 400 ms, rendering `value.round()`. Apply the same treatment to the counts in `CompactQueueHeader`'s segmented control.

**One-shot only.** `PulseDot` and `ScanLine` already hang `pumpAndSettle` forever; nothing here may join that list.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `flutter test test/widget/queue_tab_test.dart`
Expected: PASS

- [ ] **Step 6: Run the full gate and commit**

```bash
flutter analyze && flutter test
git add lib/features/recordings/presentation/queue_tab.dart lib/features/recordings/presentation/queue_metrics.dart lib/features/recordings/presentation/compact_queue_header.dart test/widget/queue_tab_test.dart
git commit -m "feat(momentum): animate a capture leaving the desk"
```

---

### Task 9: The `DAY CLOSED` card

**Files:**
- Create: `lib/features/momentum/presentation/day_closed_card.dart`
- Modify: `lib/features/recordings/presentation/queue_tab.dart`
- Test: `test/widget/day_closed_card_test.dart`

**Interfaces:**
- Consumes: `MomentumSnapshot` (Task 3)
- Produces: `DayClosedCard({required MomentumSnapshot snapshot, required bool deskClear, required int daysSinceDeskClear, required VoidCallback onDismiss})`

**The rule that must not be softened:** the card **never appears on a day below target**. Its absence is the absence of a message, not a verdict. An app that comments on the user's empty days teaches avoidance exactly when returning matters most. There is no "you missed it" state, no amber variant, no nudge.

- [ ] **Step 1: Write the failing tests**

```dart
  testWidgets('is silent below target', (WidgetTester tester) async {
    // A snapshot with today: 1, target: 3 must render nothing at all —
    // find.byType(DayClosedCard) inside the queue finds nothing.
  });

  testWidgets('appears at target with the count and the pace', (
    WidgetTester tester,
  ) async {
    // expect(find.textContaining('DAY CLOSED'), findsOneWidget);
    // expect(find.textContaining('4 closed'), findsOneWidget);
    // expect(find.textContaining('target 3'), findsOneWidget);
  });

  testWidgets('reads DESK CLEAR when the queue emptied', (
    WidgetTester tester,
  ) async {
    // expect(find.textContaining('DESK CLEAR'), findsOneWidget);
    // expect(find.textContaining('first time in 23 days'), findsOneWidget);
  });

  testWidgets('dismisses', (WidgetTester tester) async {
    // Tap the ✕, assert onDismiss fired.
  });

  testWidgets('settles', (WidgetTester tester) async {
    // await tester.pumpAndSettle();  // the slide-in is one-shot
  });
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/widget/day_closed_card_test.dart`
Expected: FAIL — `day_closed_card.dart` does not exist

- [ ] **Step 3: Write the card**

A plain `ConsoleCard` — **not a modal, not an overlay, not a snackbar.** This app has none of those and reserves dialogs for destructive confirmation only. Slide in with `AnimatedSize`, 220 ms, one-shot. No `const` constructor.

Heading is `DESK CLEAR` when `deskClear`, otherwise `DAY CLOSED`. Second line on a desk-clear day reads `first time in $daysSinceDeskClear days` — the variable, informational payload that keeps the moment from habituating. Third line is `pace ${pace.toStringAsFixed(1)}/day` with `↑`/`↓` only when `snapshot.rising` is non-null.

- [ ] **Step 4: Mount it in the queue**

In `_QueueTabState`, hold `bool _dayCardDismissed = false` and a `DateTime? _dayCardShownFor`. Render the card above `ReviewedStrip` when `snapshot.metTarget && !_dayCardDismissed`.

**Not restored after a restart** — one card per day, held in memory only. Nothing about it goes to disk.

Play the second cue here, in the branch that *first* renders the card:

```dart
    if (snapshot.metTarget && _dayCardShownFor != today) {
      _dayCardShownFor = today;
      unawaited(widget.cuePlayer.play(Cue.dayClosed).catchError((Object _) {}));
    }
```

`_dayCardShownFor` is what keeps it to once a day: `build` runs on every pipeline tick, so a bare `metTarget` check would fire the cue several times a minute for the rest of the evening. Guarding on the *day* rather than on `_dayCardDismissed` also means dismissing the card does not re-arm the sound.

Add a test:

```dart
  testWidgets('the day cue fires once, not on every rebuild', (
    WidgetTester tester,
  ) async {
    // Pump the queue at target, then pump three more frames.
    // expect(cues.played, <Cue>[Cue.dayClosed]);
  });
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `flutter test test/widget/day_closed_card_test.dart`
Expected: PASS, 5 tests

- [ ] **Step 6: Run the full gate and commit**

```bash
flutter analyze && flutter test
git add lib/features/momentum/presentation/day_closed_card.dart lib/features/recordings/presentation/queue_tab.dart test/widget/day_closed_card_test.dart
git commit -m "feat(momentum): add the once-a-day DAY CLOSED card"
```

---

### Task 10: Wire the shell and the Config toggle

**Files:**
- Modify: `lib/features/recordings/presentation/recordings_page.dart`, `lib/features/settings/presentation/config_tab.dart`

- [ ] **Step 1: Construct the real implementations**

In `_RecordingsPageState.initState`, beside the existing `FocusTimerController` construction (~line 249):

```dart
    momentum = MomentumController(
      log: const FileClosureLog(),
      sessions: () => timer.sessions,
    );
```

Pass `closureLog: const FileClosureLog()` to `RecordingsController` (~line 175), and `cuePlayer` where the settings say cues are on.

- [ ] **Step 2: Call the startup reads after `initialize`, never inside it**

```dart
    await controller.initialize();
    await controller.recoverOrphans();   // existing
    await controller.loadClosures();     // new
    await momentum.initialize();         // new
```

Both read real files, which an in-memory repository fake cannot stand in for — the same reason `recoverOrphans` lives here rather than inside `initialize`.

- [ ] **Step 3: Merge the listenable and dispose**

Add `momentum` to the merged listenable the shell already builds, and dispose it alongside the others.

- [ ] **Step 4: Push `cueSounds` on every settings change**

In the existing settings listener that pushes `settings.transcriptionService` / `settings.enrichmentService` / `settings.audio`, add the cue player: `controller.cuePlayer = settings.cueSounds ? _cuePlayer : const NoopCuePlayer();`

- [ ] **Step 5: Add the Config toggle**

In `config_tab.dart`, in the section carrying the other feedback preferences, add a switch bound to `settings.cueSounds` calling `settings.setCueSounds(value)`. Label: `CONFIRMATION SOUNDS`. Blurb: `A short tone when a capture leaves the desk, and a second when the day reaches its target.`

- [ ] **Step 6: Run the app and look at it**

**This step is not optional and cannot be replaced by the test suite.** The light theme once shipped `flutter analyze` clean, 475 tests green and two purpose-built source-level guards while half the app painted the previous palette — every widget rendered *correctly* for the palette it held, so there was no wrong pixel to assert against. One screenshot found it in a second.

```bash
flutter build macos --release
open "build/macos/Build/Products/Release/Augustyniak Capture.app"
```

Check, in both light and dark themes:
- closing a row animates out rather than vanishing, and the counter moves
- the cue is audible but does not make you flinch
- the `MOMENTUM` panel renders in all three states (rename `closures.jsonl` to force the empty one; `chmod 000` it to force the unreadable one)
- the `DAY CLOSED` card appears at target and **does not** appear below it
- `CLOSED BY PROJECT` and `WHERE IT WENT` are both visible and not confusable

- [ ] **Step 7: Run the full gate and commit**

```bash
flutter analyze && flutter test
git add lib/features/recordings/presentation/recordings_page.dart lib/features/settings/presentation/config_tab.dart
git commit -m "feat(momentum): wire the closure log, cues and panel into the shell"
```

---

### Task 11: Document it in CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

`CLAUDE.md` documents every store, seam and invariant in this repo, and a feature absent from it is a feature the next session will violate.

- [ ] **Step 1: Add a `**Momentum**` section**

After the focus-timer section. Cover, in the file's existing voice — the decision and the reason it is not the obvious alternative:

- the reward hangs on **closing**, never on capturing, and why (Goodhart: capture volume is farmable and the farmed items land back in the queue)
- `closures.jsonl` is the **third append-only store**, and why it is not derived from `recordings.json` (rewritten wholesale, shrinks on delete)
- **one closure per capture, ever**, enforced in `_update` rather than at the three call sites that set the flag — and that `route` and the handoff set it themselves, so per-call-site appends would double-count
- the target is the **median across active days**, floored at 1, derived on read
- the card is **silent both ways** and never appears below target
- cues are **−18 dBFS, not −3**, and why (a flinch gets the system volume muted, taking the alarm with it)
- `MOMENTUM` panel naming: `CLOSED BY PROJECT`, never `WHERE IT WENT`, which is taken

- [ ] **Step 2: Update the persistence list**

Add `closures.jsonl` to the four-JSON-indexes-plus-history list, noting it is the third append-only file.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: document the momentum loop"
```

---

## Self-Review

**Spec coverage.** Every section of the spec maps to a task: the store (1, 2), one-closure-per-capture and the `_update` funnel (4), pace and target (3), the four UI surfaces (7, 8, 9), sound (6), wiring (10), and the seven listed test hazards distributed across 3, 4, 7, 8, 9. The "what we are not building" table needs no task — it is enforced by absence, and Task 11 records it so a later session does not add streaks back.

**Known softness, flagged rather than hidden.** Tasks 1, 2, 3 and 4 give complete compiling test code. Tasks 5, 7, 8 and 9 give widget-test *bodies* as commented assertions, because they depend on `hostTab` and the queue harness in `test/support/harness.dart` that an implementer must read anyway. The assertions themselves are exact and must not be weakened. This is the only place the plan asks for code it does not spell out.

**Type consistency, re-checked after the review found two breaks.**

- `ClosureEvent`/`ClosureKind`/`ClosureLog` (1) are used unchanged in 2, 4, 5.
- `MomentumSnapshot`/`paceOf`/`targetFrom`/`closuresByDay`/`activeDaysIn` (3) are used unchanged in 5, 7, 9.
- `focusDayOf` is imported from the timer's domain in 3 and 5, and reimplemented nowhere.
- **Fixed:** Task 4 originally called a `_projectFor` helper that does not exist. The real seam is `_projectById` (a `Project? Function(String)?`, already used at ~line 1398).
- **Fixed:** Task 10 assigned `controller.cuePlayer`, which no earlier task declared. Declaring it in Task 4 was impossible — `CuePlayer` does not exist until Task 6 — so it is declared there, in the task that creates the type.
- `Cue`/`CuePlayer` (6) are consumed in 9 (the `dayClosed` cue) and 10 (the settings push).

**Ordering.** Tasks 1–6 are pure additions and land safely in any order after 1. Task 4 is the only one that edits a load-bearing existing file and has its own vacuity check (Step 8). Tasks 7–9 depend on 5, and 9 additionally on 6. Task 10 depends on everything. Task 11 last.
