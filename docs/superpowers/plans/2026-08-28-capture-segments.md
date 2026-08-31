# Capture Segments Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A capture that already exists can gain further source artifacts — a second recording, a typed addition, a picked file — without becoming a second row and without weakening the ordering guarantee that governs the first one.

**Architecture:** A new `CaptureSegment` value type becomes the unit of processing and retry. `Recording` gains an optional segment list whose absence synthesises one segment from the existing top-level fields, so every legacy row and every existing constructor call site stays valid. `Processor.process` takes a segment instead of a recording; `_processOne` runs only the segments that have no text yet and accumulates their output into `transcript`. Everything that maps a row to a file on disk — orphan recovery, deletion, the archive, the sync path policy, the vault — learns to walk the list.

**Tech Stack:** Flutter / Dart 3.10, plain `ChangeNotifier` + constructor injection, `flutter_test`, pure-Dart test suites over temp directories.

**Spec:** `docs/superpowers/specs/2026-08-28-capture-segments-design.md`

## Global Constraints

- **Persist before process, unchanged.** Every capture entry point keeps the five-step order in `CLAUDE.md`; the append path adds one rule — the parent row is not touched until the new fragment's file is verified with `length > 0`.
- **Top-level source fields describe segment 0 exactly**: `filePath`, `type`, `sourceMimeType`, `sizeBytes`, `contentHash`. Aggregates are getters (`totalDurationMs`, `totalSizeBytes`). Never recompute `contentHash` across segments — it is the archive's deduplication contract.
- **`transcript` accumulates and is never recomputed** from the segment list. A recompute would silently undo a hand edit.
- **Backward compatibility both ways.** A row with no `segments` key loads as exactly one segment; a row that has never gained a fragment serialises byte for byte as before (the key is omitted, the same rule `shortcuts` and the `command*` keys follow).
- **User-facing strings in code are English.** Identifiers and comments too.
- Analyze/lint config is `flutter_lints` + `avoid_print` + `prefer_final_locals`; `prefer_const_constructors_in_immutables` is off deliberately.
- Every commit message is Conventional Commits, imperative, lowercase subject at most 72 chars, with `Refs #83` in the footer. No mention of the tool that wrote it.
- Work happens in the worktree `.worktrees/feat-83-capture-segments` on branch `feat/83-capture-segments`. Run `flutter pub get` there once before the first task.
- Gate for every task: `flutter analyze` clean and `flutter test` green before the commit.

---

### Task 1: `CaptureSegment`

**Files:**
- Create: `lib/features/recordings/domain/capture_segment.dart`
- Test: `test/capture_segment_test.dart`

**Interfaces:**
- Consumes: `CaptureType` from `lib/features/recordings/domain/capture_type.dart`.
- Produces: `class CaptureSegment` with `final int index; final String filePath; final CaptureType type; final String? sourceMimeType; final DateTime createdAt; final int durationMs; final int sizeBytes; final String? contentHash; final String? text; final String? error;`, `bool get isPending`, `CaptureSegment copyWith({String? text, bool clearText, String? error, bool clearError, String? contentHash, int? durationMs, int? sizeBytes})`, `Map<String, dynamic> toJson()`, `factory CaptureSegment.fromJson(Map<String, dynamic>)`, `static List<CaptureSegment> listFromJson(dynamic raw)`, and the top-level function `String appendSegmentText(String? existing, String addition)`.

- [ ] **Step 1: Write the failing test**

```dart
// test/capture_segment_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_segment.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';

void main() {
  final DateTime at = DateTime.utc(2026, 8, 28, 10, 30);

  CaptureSegment sample({int index = 1, String? text}) => CaptureSegment(
    index: index,
    filePath: '/tmp/recordings/abc-$index.m4a',
    type: CaptureType.audioRecording,
    sourceMimeType: 'audio/mp4',
    createdAt: at,
    durationMs: 4200,
    sizeBytes: 1024,
    contentHash: 'a' * 64,
    text: text,
  );

  group('CaptureSegment', () {
    test('round-trips through JSON', () {
      final CaptureSegment restored = CaptureSegment.fromJson(
        sample(text: 'hello').toJson(),
      );
      expect(restored.index, 1);
      expect(restored.filePath, '/tmp/recordings/abc-1.m4a');
      expect(restored.type, CaptureType.audioRecording);
      expect(restored.sourceMimeType, 'audio/mp4');
      expect(restored.createdAt, at);
      expect(restored.durationMs, 4200);
      expect(restored.sizeBytes, 1024);
      expect(restored.contentHash, 'a' * 64);
      expect(restored.text, 'hello');
      expect(restored.error, isNull);
    });

    test('is pending exactly while it has no text', () {
      expect(sample().isPending, isTrue);
      expect(sample(text: '').isPending, isFalse);
      expect(sample(text: 'done').isPending, isFalse);
    });

    test('copyWith clears text and error explicitly', () {
      final CaptureSegment failed = sample().copyWith(error: 'no profile');
      expect(failed.error, 'no profile');
      expect(failed.copyWith(clearError: true).error, isNull);
      expect(sample(text: 'x').copyWith(clearText: true).text, isNull);
    });

    test('an unknown type degrades rather than throwing', () {
      final Map<String, dynamic> json = sample().toJson()
        ..['type'] = 'hologram';
      expect(CaptureSegment.fromJson(json).type, CaptureType.audioRecording);
    });

    test('listFromJson drops unreadable rows one at a time', () {
      final List<CaptureSegment> parsed = CaptureSegment.listFromJson(
        <dynamic>[sample(index: 0).toJson(), 42, sample(index: 1).toJson()],
      );
      expect(parsed.map((CaptureSegment s) => s.index), <int>[0, 1]);
    });

    test('listFromJson answers empty for anything that is not a list', () {
      expect(CaptureSegment.listFromJson(null), isEmpty);
      expect(CaptureSegment.listFromJson('nope'), isEmpty);
    });
  });

  group('appendSegmentText', () {
    test('joins with a blank line', () {
      expect(appendSegmentText('first', 'second'), 'first\n\nsecond');
    });

    test('an empty existing text is replaced, not padded', () {
      expect(appendSegmentText(null, 'first'), 'first');
      expect(appendSegmentText('   ', 'first'), 'first');
    });

    test('a blank addition leaves the text alone', () {
      expect(appendSegmentText('first', '   '), 'first');
      expect(appendSegmentText(null, ''), '');
    });
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `flutter test test/capture_segment_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:augustyniak_capture/features/recordings/domain/capture_segment.dart'`.

- [ ] **Step 3: Write the implementation**

```dart
// lib/features/recordings/domain/capture_segment.dart
import 'capture_type.dart';

/// One source artifact belonging to a capture.
///
/// A capture starts with exactly one segment and gains further ones when the
/// user appends a fragment. The segment — not the capture — is the unit of
/// processing and of retry: it carries its own [CaptureType], so a photo
/// appended to an audio note reaches `OcrProcessor`, and its own [text] and
/// [error], so a fragment that fails cannot cost the fragments that worked.
///
/// **Pending is defined by [text] alone.** No per-segment status enum exists:
/// `RecordingStatus` already answers queued/running/failed for the capture, and
/// a second persisted enum would be a second thing to keep in agreement.
class CaptureSegment {
  const CaptureSegment({
    required this.index,
    required this.filePath,
    required this.type,
    required this.createdAt,
    this.sourceMimeType,
    this.durationMs = 0,
    this.sizeBytes = 0,
    this.contentHash,
    this.text,
    this.error,
  });

  /// Position in the capture, and the suffix of the file name for anything
  /// past the first: segment 0 is `<id>.<ext>`, segment n is `<id>-<n>.<ext>`.
  final int index;
  final String filePath;
  final CaptureType type;
  final String? sourceMimeType;
  final DateTime createdAt;
  final int durationMs;
  final int sizeBytes;

  /// SHA-256 of this segment's bytes, or null until the backfill computes it.
  final String? contentHash;

  /// Processor output for this segment. Null means it has not been processed.
  final String? text;

  /// Why the last attempt at this segment failed. Independent of the capture's
  /// `error`, which reports whichever segment failed most recently.
  final String? error;

  bool get isPending => text == null;

  CaptureSegment copyWith({
    String? text,
    bool clearText = false,
    String? error,
    bool clearError = false,
    String? contentHash,
    int? durationMs,
    int? sizeBytes,
  }) {
    return CaptureSegment(
      index: index,
      filePath: filePath,
      type: type,
      sourceMimeType: sourceMimeType,
      createdAt: createdAt,
      durationMs: durationMs ?? this.durationMs,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      contentHash: contentHash ?? this.contentHash,
      text: clearText ? null : (text ?? this.text),
      error: clearError ? null : (error ?? this.error),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'index': index,
    'filePath': filePath,
    'type': type.name,
    'sourceMimeType': sourceMimeType,
    'createdAt': createdAt.toIso8601String(),
    'durationMs': durationMs,
    'sizeBytes': sizeBytes,
    'contentHash': contentHash,
    'text': text,
    'error': error,
  };

  factory CaptureSegment.fromJson(Map<String, dynamic> json) {
    return CaptureSegment(
      index: json['index'] as int,
      filePath: json['filePath'] as String,
      // Degrades rather than throwing, the same rule `Recording.type` follows.
      type: CaptureType.fromName(json['type'] as String?),
      sourceMimeType: json['sourceMimeType'] is String
          ? json['sourceMimeType'] as String
          : null,
      createdAt: DateTime.parse(json['createdAt'] as String),
      durationMs: json['durationMs'] as int? ?? 0,
      sizeBytes: json['sizeBytes'] as int? ?? 0,
      contentHash: json['contentHash'] is String
          ? json['contentHash'] as String
          : null,
      text: json['text'] is String ? json['text'] as String : null,
      error: json['error'] is String ? json['error'] as String : null,
    );
  }

  /// Unreadable entries are dropped one at a time rather than throwing out of
  /// the whole load — the same rule `tags` and `routes` follow.
  static List<CaptureSegment> listFromJson(dynamic raw) {
    if (raw is! List) return const <CaptureSegment>[];
    final List<CaptureSegment> parsed = <CaptureSegment>[];
    for (final dynamic entry in raw) {
      if (entry is! Map<String, dynamic>) continue;
      try {
        parsed.add(CaptureSegment.fromJson(entry));
      } catch (_) {
        // One unreadable segment must not cost the capture.
      }
    }
    return parsed;
  }
}

/// How a segment's output joins the capture's text.
///
/// Accumulation, never a recompute of the whole join: `editTranscript` exists
/// and people correct transcripts, so rebuilding the text from the segments
/// after an append would silently undo a hand edit.
String appendSegmentText(String? existing, String addition) {
  final String trimmed = addition.trim();
  if (existing == null || existing.trim().isEmpty) return trimmed;
  if (trimmed.isEmpty) return existing;
  return '$existing\n\n$trimmed';
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `flutter test test/capture_segment_test.dart`
Expected: PASS, 9 tests.

- [ ] **Step 5: Commit**

```bash
git add lib/features/recordings/domain/capture_segment.dart test/capture_segment_test.dart
git commit -m "feat(recordings): add CaptureSegment, the unit of processing

A capture is about to be able to hold more than one source artifact, so
the thing a processor reads and a retry re-runs has to become smaller
than a capture. A segment carries its own CaptureType, text and error:
a photo appended to an audio note reaches the OCR processor, and a
fragment that fails cannot cost the fragments that worked.

appendSegmentText accumulates rather than rebuilding the join, because
a recompute after an append would silently undo a hand-edited
transcript.

Refs #83"
```

---

### Task 2: `Recording.segments`

**Files:**
- Modify: `lib/features/recordings/domain/recording.dart`
- Test: `test/recording_segments_test.dart`

**Interfaces:**
- Consumes: `CaptureSegment` from Task 1.
- Produces: on `Recording` — constructor parameter `List<CaptureSegment>? segments`, getter `List<CaptureSegment> get segments` (synthesising one segment from the top-level fields when none are stored), `bool get hasStoredSegments`, `int get totalDurationMs`, `int get totalSizeBytes`, `int get nextSegmentIndex`, and `copyWith({List<CaptureSegment>? segments})`.

- [ ] **Step 1: Write the failing test**

```dart
// test/recording_segments_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_segment.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';

void main() {
  final DateTime at = DateTime.utc(2026, 8, 28, 10);

  Recording base({List<CaptureSegment>? segments}) => Recording(
    id: 'abc',
    filePath: '/tmp/recordings/abc.m4a',
    createdAt: at,
    durationMs: 5000,
    sizeBytes: 2048,
    contentHash: 'b' * 64,
    status: RecordingStatus.completed,
    type: CaptureType.audioRecording,
    transcript: 'first fragment',
    segments: segments,
  );

  Recording withTwo() => base(
    segments: <CaptureSegment>[
      CaptureSegment(
        index: 0,
        filePath: '/tmp/recordings/abc.m4a',
        type: CaptureType.audioRecording,
        createdAt: at,
        durationMs: 5000,
        sizeBytes: 2048,
        contentHash: 'b' * 64,
        text: 'first fragment',
      ),
      CaptureSegment(
        index: 1,
        filePath: '/tmp/recordings/abc-1.txt',
        type: CaptureType.text,
        createdAt: at,
        sizeBytes: 12,
        text: 'second fragment',
      ),
    ],
  );

  group('a row with no stored segments', () {
    test('synthesises exactly one segment from the top-level fields', () {
      final List<CaptureSegment> segments = base().segments;
      expect(segments, hasLength(1));
      expect(segments.single.index, 0);
      expect(segments.single.filePath, '/tmp/recordings/abc.m4a');
      expect(segments.single.type, CaptureType.audioRecording);
      expect(segments.single.durationMs, 5000);
      expect(segments.single.sizeBytes, 2048);
      expect(segments.single.contentHash, 'b' * 64);
      expect(segments.single.text, 'first fragment');
      expect(base().hasStoredSegments, isFalse);
    });

    test('serialises byte for byte as before', () {
      expect(base().toJson().containsKey('segments'), isFalse);
    });

    test('legacy JSON with no segments key loads as one segment', () {
      final Recording restored = Recording.fromJson(base().toJson());
      expect(restored.segments, hasLength(1));
      expect(restored.hasStoredSegments, isFalse);
    });
  });

  group('a row with stored segments', () {
    test('round-trips through JSON', () {
      final Recording restored = Recording.fromJson(withTwo().toJson());
      expect(restored.hasStoredSegments, isTrue);
      expect(restored.segments, hasLength(2));
      expect(restored.segments[1].type, CaptureType.text);
      expect(restored.segments[1].text, 'second fragment');
    });

    test('top-level source fields still describe segment 0 exactly', () {
      final Recording item = withTwo();
      expect(item.filePath, item.segments.first.filePath);
      expect(item.sizeBytes, item.segments.first.sizeBytes);
      expect(item.contentHash, item.segments.first.contentHash);
      expect(item.durationMs, item.segments.first.durationMs);
    });

    test('aggregates are getters, never the persisted fields', () {
      expect(withTwo().totalDurationMs, 5000);
      expect(withTwo().totalSizeBytes, 2060);
    });

    test('nextSegmentIndex is one past the highest index in use', () {
      expect(base().nextSegmentIndex, 1);
      expect(withTwo().nextSegmentIndex, 2);
    });

    test('an empty stored list falls back to synthesis', () {
      final Map<String, dynamic> json = base().toJson()
        ..['segments'] = <dynamic>[];
      final Recording restored = Recording.fromJson(json);
      expect(restored.segments, hasLength(1));
      expect(restored.hasStoredSegments, isFalse);
    });

    test('copyWith carries the segments through an unrelated change', () {
      final Recording renamed = withTwo().copyWith(title: 'Plan');
      expect(renamed.segments, hasLength(2));
      expect(renamed.title, 'Plan');
    });
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `flutter test test/recording_segments_test.dart`
Expected: FAIL — `No named parameter with the name 'segments'`.

- [ ] **Step 3: Write the implementation**

In `lib/features/recordings/domain/recording.dart`:

1. Add `import 'capture_segment.dart';` beside the existing domain imports.
2. Add the constructor parameter as the **last** entry, and store it privately:

```dart
  const Recording({
    required this.id,
    // ... every existing parameter unchanged ...
    this.artifacts = const <AgentArtifact>[],
    List<CaptureSegment>? segments,
  }) : _segments = segments;
```

3. Add the field, the getters and the doc beneath `artifacts`:

```dart
  /// The capture's source artifacts, oldest first, or null on every row that
  /// has never gained a fragment.
  ///
  /// Private and nullable for the same reason `AppSettings._shortcuts` is:
  /// **absent** and **present** are different facts. Absent means the capture
  /// is what it always was — one source — and the key stays out of
  /// `recordings.json`, so such a row serialises byte for byte as it did
  /// before this existed. Present is authoritative.
  final List<CaptureSegment>? _segments;

  /// Every source artifact, always at least one.
  ///
  /// A row with nothing stored synthesises its single segment from the
  /// top-level fields, which is what keeps every legacy row and every existing
  /// construction site of this class valid without a migration.
  List<CaptureSegment> get segments =>
      _segments ??
      <CaptureSegment>[
        CaptureSegment(
          index: 0,
          filePath: filePath,
          type: type,
          sourceMimeType: sourceMimeType,
          createdAt: createdAt,
          durationMs: durationMs,
          sizeBytes: sizeBytes,
          contentHash: contentHash,
          text: transcript,
        ),
      ];

  bool get hasStoredSegments => _segments != null;

  /// Sum across segments. The persisted `durationMs` and `sizeBytes` keep
  /// describing segment 0 — they are the archive's deduplication contract —
  /// so the UI reads these instead.
  int get totalDurationMs => segments.fold(
    0,
    (int sum, CaptureSegment segment) => sum + segment.durationMs,
  );

  int get totalSizeBytes => segments.fold(
    0,
    (int sum, CaptureSegment segment) => sum + segment.sizeBytes,
  );

  /// One past the highest index in use, never the list length: a segment
  /// dropped by the sync path policy would otherwise hand the next append a
  /// file name that is already taken.
  int get nextSegmentIndex =>
      segments.fold(
        -1,
        (int highest, CaptureSegment segment) =>
            segment.index > highest ? segment.index : highest,
      ) +
      1;
```

4. Add the `copyWith` parameter and thread it:

```dart
  Recording copyWith({
    // ... existing parameters ...
    List<AgentArtifact>? artifacts,
    List<CaptureSegment>? segments,
  }) {
    return Recording(
      // ... existing arguments ...
      artifacts: artifacts ?? this.artifacts,
      segments: segments ?? _segments,
    );
  }
```

5. In `toJson`, add a conditional entry as the last member of the literal:

```dart
    'artifacts': artifacts.map((AgentArtifact a) => a.toJson()).toList(),
    if (_segments != null)
      'segments': _segments.map((CaptureSegment s) => s.toJson()).toList(),
  };
```

6. In `fromJson`, add as the last argument:

```dart
      artifacts: AgentArtifact.listFromJson(json['artifacts']),
      // An empty parsed list means every segment row was unreadable, which is
      // the same information as no list at all — fall back to synthesis rather
      // than to a capture with no sources.
      segments: switch (CaptureSegment.listFromJson(json['segments'])) {
        final List<CaptureSegment> parsed when parsed.isNotEmpty => parsed,
        _ => null,
      },
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `flutter test test/recording_segments_test.dart test/recording_test.dart`
Expected: PASS. `recording_test.dart` must stay green untouched — that is the backward-compatibility proof.

- [ ] **Step 5: Pin that segments live only in the payload**

`segments` gets no SQLite column: it rides inside `json_payload`, exactly as `transcript` does, and is therefore lost by a row that `_loadFromDatabase` had to rebuild from the columns. The existing mechanism already covers it — that loader tracks the ids it rebuilt and prefers the index's version of those rows — so this step pins the behaviour rather than changing it.

Add to `test/sqlite_index_divergence_test.dart`, following the shape of the `transcript` case already there:

```dart
  test('a row rebuilt from the columns does not lose its segments', () async {
    // Arrange: write a two-segment capture through the repository, then
    // corrupt only its json_payload in the recordings table (the same
    // mutation the transcript case uses), leaving recordings.json intact.
    // Act: loadAll().
    // Assert:
    //   expect(loaded.single.segments, hasLength(2));
    //   expect(loaded.single.transcript, 'first fragment\n\nsecond fragment');
    // i.e. the index's version won, exactly as it does for a lost transcript.
  });
```

Copy the arrange/act mechanics verbatim from the neighbouring `transcript` test in that file — it already knows how to corrupt one payload — and replace only the assertions with the two above.

Run: `flutter test test/sqlite_index_divergence_test.dart`
Expected: PASS. If it fails, the divergence guard does not cover payload-only fields generically and Task 12's documentation note is wrong; stop and report rather than widening the loader here.

- [ ] **Step 6: Commit**

```bash
git add lib/features/recordings/domain/recording.dart test/recording_segments_test.dart
git commit -m "feat(recordings): let a capture hold a list of segments

The list is private and nullable, the same three-state shape
AppSettings._shortcuts uses: absent means the capture is what it always
was and the key stays out of recordings.json, so a row that never
gained a fragment serialises byte for byte as before.

The getter synthesises one segment from the top-level fields when
nothing is stored, which keeps every legacy row and every existing
construction site valid with no migration. Sums are getters;
durationMs, sizeBytes and contentHash keep describing segment 0,
because those are the archive's deduplication contract.

Refs #83"
```

---

### Task 3: Files on disk — naming, deletion, orphan recovery

**Files:**
- Modify: `lib/features/recordings/data/recordings_repository.dart` (`deleteArtifacts` at :54, `findOrphans` at :381, add `createSegmentFile`)
- Test: `test/capture_segment_files_test.dart`

**Interfaces:**
- Consumes: `Recording.segments` from Task 2.
- Produces: `Future<File> RecordingsRepository.createSegmentFile(String id, int index, String extension)` returning `<id>.<ext>` for index 0 and `<id>-<index>.<ext>` above it; `deleteArtifacts` removing every segment file; `findOrphans` skipping any file a stored segment already claims.

- [ ] **Step 1: Write the failing test**

```dart
// test/capture_segment_files_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_segment.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';

void main() {
  late Directory dir;
  late RecordingsRepository repository;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('segment-files');
    repository = RecordingsRepository(directoryProvider: () async => dir);
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Recording twoSegments() {
    final DateTime at = DateTime.utc(2026, 8, 28);
    return Recording(
      id: 'abc',
      filePath: p.join(dir.path, 'abc.m4a'),
      createdAt: at,
      durationMs: 1000,
      sizeBytes: 10,
      status: RecordingStatus.completed,
      type: CaptureType.audioRecording,
      segments: <CaptureSegment>[
        CaptureSegment(
          index: 0,
          filePath: p.join(dir.path, 'abc.m4a'),
          type: CaptureType.audioRecording,
          createdAt: at,
          sizeBytes: 10,
        ),
        CaptureSegment(
          index: 1,
          filePath: p.join(dir.path, 'abc-1.m4a'),
          type: CaptureType.audioRecording,
          createdAt: at,
          sizeBytes: 10,
        ),
      ],
    );
  }

  test('segment 0 keeps the plain name, later ones are suffixed', () async {
    expect(
      p.basename((await repository.createSegmentFile('abc', 0, 'm4a')).path),
      'abc.m4a',
    );
    expect(
      p.basename((await repository.createSegmentFile('abc', 2, 'txt')).path),
      'abc-2.txt',
    );
  });

  test('deleteArtifacts removes every segment and the poster', () async {
    await File(p.join(dir.path, 'abc.m4a')).writeAsString('one');
    await File(p.join(dir.path, 'abc-1.m4a')).writeAsString('two');
    await File(p.join(dir.path, 'abc.thumb.jpg')).writeAsString('poster');

    await repository.deleteArtifacts(twoSegments());

    expect(await File(p.join(dir.path, 'abc.m4a')).exists(), isFalse);
    expect(await File(p.join(dir.path, 'abc-1.m4a')).exists(), isFalse);
    expect(await File(p.join(dir.path, 'abc.thumb.jpg')).exists(), isFalse);
  });

  test('findOrphans does not re-adopt an indexed segment file', () async {
    await File(p.join(dir.path, 'abc.m4a')).writeAsString('one');
    await File(p.join(dir.path, 'abc-1.m4a')).writeAsString('two');

    final List<Recording> orphans = await repository.findOrphans(
      <Recording>[twoSegments()],
    );

    expect(orphans, isEmpty);
  });

  test('a segment file whose row is gone is still recovered', () async {
    await File(p.join(dir.path, 'lost-1.m4a')).writeAsString('two');

    final List<Recording> orphans = await repository.findOrphans(<Recording>[]);

    expect(orphans, hasLength(1));
    expect(orphans.single.id, 'lost-1');
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `flutter test test/capture_segment_files_test.dart`
Expected: FAIL — `createSegmentFile` is not defined; the deletion test leaves `abc-1.m4a` on disk; the orphan test reports one orphan named `abc-1`.

- [ ] **Step 3: Write the implementation**

Add `import '../domain/capture_segment.dart';` to the imports, then:

```dart
  /// `<id>.<ext>` for the first segment, `<id>-<n>.<ext>` for every later one.
  ///
  /// Segment 0 keeps the plain name deliberately: it is what every row already
  /// on disk points at, and what `findOrphans` recovers a capture by.
  Future<File> createSegmentFile(String id, int index, String extension) {
    return createSourceFile(index == 0 ? id : '$id-$index', extension);
  }
```

Replace `deleteArtifacts` with a version that walks the segments:

```dart
  Future<void> deleteArtifacts(Recording recording) async {
    final List<String?> paths = <String?>[
      for (final CaptureSegment segment in recording.segments) segment.filePath,
      recording.thumbPath,
      p.join(p.dirname(recording.filePath), '${recording.id}.thumb.jpg'),
    ];
    for (final String? path in paths) {
      if (path == null || path.isEmpty) continue;
      final File file = File(path);
      if (await file.exists()) await file.delete();
    }
  }
```

In `findOrphans`, build the known set from segment file names rather than from ids, keeping the id-based recovery for anything genuinely unclaimed:

```dart
  Future<List<Recording>> findOrphans(List<Recording> indexed) async {
    final Directory directory = await recordingsDirectory();
    // Matched by file name, not by id. `basenameWithoutExtension` of an
    // appended fragment is `<id>-1`, which no row is ever keyed on, so an
    // id-based comparison re-adopts every fragment as a separate capture on
    // the next launch — silently, and one launch after the append.
    final Set<String> claimed = <String>{
      for (final Recording item in indexed)
        for (final CaptureSegment segment in item.segments)
          p.basename(segment.filePath),
    };

    final List<Recording> orphans = <Recording>[];
    await for (final FileSystemEntity entity in directory.list()) {
      if (entity is! File) continue;
      final String name = p.basename(entity.path);
      if (name.endsWith('.thumb.jpg')) continue;
      if (claimed.contains(name)) continue;

      final CaptureType? type = typeForExtension(p.extension(name));
      if (type == null) continue;

      final FileStat stat = await entity.stat();
      if (stat.size == 0) continue;

      orphans.add(
        Recording(
          id: p.basenameWithoutExtension(name),
          filePath: entity.path,
          createdAt: stat.modified,
          durationMs: 0,
          sizeBytes: stat.size,
          status: RecordingStatus.saved,
          type: type,
        ),
      );
    }

    orphans.sort(
      (Recording a, Recording b) => b.createdAt.compareTo(a.createdAt),
    );
    return orphans;
  }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `flutter test test/capture_segment_files_test.dart test/index_durability_test.dart test/deletion_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/features/recordings/data/recordings_repository.dart test/capture_segment_files_test.dart
git commit -m "fix(recordings): claim segment files by name, not by id

findOrphans matched directory files against known ids, and the id it
derives from abc-1.m4a is abc-1, which no row is keyed on. Every
appended fragment would be re-adopted as a separate capture holding the
same audio — one launch after the append, with nothing on screen
connecting the two.

deleteArtifacts walked one path per row for the same reason, leaving
every fragment past the first behind as an orphan the sweep re-adopts.
Both now walk the segment list.

Refs #83"
```

---

### Task 4: `Processor` takes a segment

**Files:**
- Modify: `lib/features/processing/domain/processor.dart`, `lib/features/processing/data/transcription_processor.dart`, `lib/features/processing/data/ocr_processor.dart`, `lib/features/processing/data/video_transcription_processor.dart`
- Modify: `lib/features/recordings/presentation/recordings_controller.dart` (the one `processor.process(...)` call site inside `_processOne` at :1927)
- Modify: every test whose fake implements `Processor` (find them in Step 1)

**Interfaces:**
- Consumes: `CaptureSegment` from Task 1.
- Produces: `abstract interface class Processor { Future<String> process(CaptureSegment segment); }`. Every implementation reads `segment.filePath` and `segment.type`; none reads a capture-level field.

- [ ] **Step 1: Find every implementation and fake**

Run: `grep -rn "implements Processor\|Future<String> process(" lib test`
Expected: the implementations in `lib` (`TextPassthroughProcessor`, `UnavailableProcessor`, `TranscriptionProcessor`, `OcrProcessor`, `VideoTranscriptionProcessor`) plus the test fakes. Every hit changes in this task.

- [ ] **Step 2: Change the interface and the implementations**

```dart
// lib/features/processing/domain/processor.dart
import 'dart:io';

import '../../recordings/domain/capture_segment.dart';

/// Turns one source artifact into text.
///
/// **The rule reviewers must enforce:** a processor only ever *reads* the
/// source file. It must never write to it, move it, or delete it. On failure it
/// throws; the controller records the failure against that segment, marks the
/// capture `failed`, and the source stays on disk, retryable.
///
/// It takes a [CaptureSegment] rather than a capture because a capture can hold
/// several artifacts of different types — an appended photo on an audio note
/// has to reach the OCR processor, and the registry keys on the segment's type.
abstract interface class Processor {
  Future<String> process(CaptureSegment segment);
}

class TextPassthroughProcessor implements Processor {
  const TextPassthroughProcessor();

  @override
  Future<String> process(CaptureSegment segment) async {
    final File file = File(segment.filePath);
    if (!await file.exists()) {
      throw FileSystemException('Source file is missing.', segment.filePath);
    }
    return file.readAsString();
  }
}

class UnavailableProcessor implements Processor {
  const UnavailableProcessor(this.reason);

  final String reason;

  @override
  Future<String> process(CaptureSegment segment) async {
    throw ProcessorNotConfiguredException(reason);
  }
}
```

Leave `ProcessorNotConfiguredException` exactly as it is. In the three data processors, replace the parameter type and the `item.filePath` reads with `segment.filePath`; nothing else in those files changes.

- [ ] **Step 3: Update the one production call site**

In `_processOne`, `transcript = await processor.process(recording);` becomes `transcript = await processor.process(recording.segments.first);`. This is temporary — Task 5 replaces the whole block — and exists so the tree compiles and the suite runs between the two tasks.

- [ ] **Step 4: Run the full suite**

Run: `flutter analyze && flutter test`
Expected: PASS, with no behaviour change. Any failure here is a fake that still declares `process(Recording)`.

- [ ] **Step 5: Commit**

```bash
git add lib test
git commit -m "refactor(processing): give Processor a segment, not a capture

A capture is about to hold several artifacts and they need not share a
type: an appended photo on an audio note has to reach the OCR
processor, and ProcessorRegistry keys on the type. All implementations
already read nothing but the source path, so this is a change of
parameter rather than of behaviour.

Refs #83"
```

---

### Task 5: Process only the pending segments

**Files:**
- Modify: `lib/features/recordings/presentation/recordings_controller.dart` (`_processOne` :1927, `_extractPoster` :2119, add `_updateSegment` beside `_update` :2517)
- Test: `test/capture_segment_processing_test.dart`

**Interfaces:**
- Consumes: `Recording.segments`, `appendSegmentText`, `Processor.process(CaptureSegment)`.
- Produces: `_processOne` writing each segment's text into that segment and accumulating it into `transcript`; a failed segment recording its own `error` while earlier segments keep their text; `Future<void> _updateSegment(String id, int index, CaptureSegment Function(CaptureSegment) transform)`.

- [ ] **Step 1: Write the failing test**

```dart
// test/capture_segment_processing_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:augustyniak_capture/features/processing/domain/processor.dart';
import 'package:augustyniak_capture/features/processing/domain/processor_registry.dart';
import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_segment.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';

class _MemoryRepo extends RecordingsRepository {
  _MemoryRepo(this._dir, this.seed);
  final Directory _dir;
  final List<Recording> seed;

  @override
  Future<Directory> recordingsDirectory() async => _dir;
  @override
  Future<List<Recording>> loadAll() async => seed;
  @override
  Future<void> saveAll(List<Recording> recordings) async {}
}

/// Answers the file's own contents, so each segment produces distinct text and
/// the test can tell which one was processed.
class _EchoProcessor implements Processor {
  final List<String> seen = <String>[];

  @override
  Future<String> process(CaptureSegment segment) async {
    seen.add(p.basename(segment.filePath));
    return File(segment.filePath).readAsString();
  }
}

class _FailingProcessor implements Processor {
  @override
  Future<String> process(CaptureSegment segment) async =>
      throw const ProcessorNotConfiguredException('no vision model');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('segment-processing');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<File> write(String name, String body) async {
    final File file = File(p.join(dir.path, name));
    await file.writeAsString(body);
    return file;
  }

  CaptureSegment segment(int index, String path, {String? text}) =>
      CaptureSegment(
        index: index,
        filePath: path,
        type: CaptureType.text,
        createdAt: DateTime.utc(2026, 8, 28),
        sizeBytes: 8,
        text: text,
      );

  Recording seeded({
    required List<CaptureSegment> segments,
    String? transcript,
  }) {
    return Recording(
      id: 'abc',
      filePath: segments.first.filePath,
      createdAt: DateTime.utc(2026, 8, 28),
      durationMs: 0,
      sizeBytes: segments.first.sizeBytes,
      status: RecordingStatus.saved,
      type: segments.first.type,
      transcript: transcript,
      segments: segments,
    );
  }

  RecordingsController build(
    RecordingsRepository repository,
    Map<CaptureType, Processor> processors,
  ) {
    return RecordingsController(
      repository: repository,
      registry: ProcessorRegistry(processors),
    );
  }

  test('only the pending segment is processed and its text is appended', () async {
    final File first = await write('abc.txt', 'first fragment');
    final File second = await write('abc-1.txt', 'second fragment');
    final _EchoProcessor processor = _EchoProcessor();
    final RecordingsController controller = build(
      _MemoryRepo(dir, <Recording>[
        seeded(
          transcript: 'first fragment',
          segments: <CaptureSegment>[
            segment(0, first.path, text: 'first fragment'),
            segment(1, second.path),
          ],
        ),
      ]),
      <CaptureType, Processor>{CaptureType.text: processor},
    );

    await controller.initialize();
    await controller.retryTranscription('abc');
    await controller.waitForProcessing();

    final Recording item = controller.recordings.single;
    expect(
      processor.seen,
      <String>['abc-1.txt'],
      reason: 'the first fragment already has text and must not be re-sent',
    );
    expect(item.transcript, 'first fragment\n\nsecond fragment');
    expect(item.segments[1].text, 'second fragment');
    expect(item.status, RecordingStatus.completed);
    controller.dispose();
  });

  test('a failing segment keeps the text of the ones that worked', () async {
    final File first = await write('abc.txt', 'first fragment');
    final File second = await write('abc-1.jpg', 'not an image');
    final RecordingsController controller = build(
      _MemoryRepo(dir, <Recording>[
        seeded(
          segments: <CaptureSegment>[
            segment(0, first.path),
            CaptureSegment(
              index: 1,
              filePath: second.path,
              type: CaptureType.image,
              createdAt: DateTime.utc(2026, 8, 28),
              sizeBytes: 12,
            ),
          ],
        ),
      ]),
      <CaptureType, Processor>{
        CaptureType.text: _EchoProcessor(),
        CaptureType.image: _FailingProcessor(),
      },
    );

    await controller.initialize();
    await controller.retryTranscription('abc');
    await controller.waitForProcessing();

    final Recording item = controller.recordings.single;
    expect(item.status, RecordingStatus.failed);
    expect(item.transcript, 'first fragment');
    expect(item.segments[0].text, 'first fragment');
    expect(item.segments[1].text, isNull);
    expect(item.segments[1].error, contains('vision'));
    controller.dispose();
  });

  test('a hand-edited transcript survives the next segment', () async {
    final File first = await write('abc.txt', 'first fragment');
    final File second = await write('abc-1.txt', 'second fragment');
    final RecordingsController controller = build(
      _MemoryRepo(dir, <Recording>[
        seeded(
          transcript: 'FIRST FRAGMENT, corrected by hand',
          segments: <CaptureSegment>[
            segment(0, first.path, text: 'first fragment'),
            segment(1, second.path),
          ],
        ),
      ]),
      <CaptureType, Processor>{CaptureType.text: _EchoProcessor()},
    );

    await controller.initialize();
    await controller.retryTranscription('abc');
    await controller.waitForProcessing();

    expect(
      controller.recordings.single.transcript,
      'FIRST FRAGMENT, corrected by hand\n\nsecond fragment',
    );
    controller.dispose();
  });
}
```

Check the real `RecordingsController` constructor before running: most parameters have defaults. Pass only `repository` and `registry` if that compiles; otherwise add whatever else is required, following `test/processing_queue_test.dart` as the reference.

- [ ] **Step 2: Run the test to verify it fails**

Run: `flutter test test/capture_segment_processing_test.dart`
Expected: FAIL — the first test reports `processor.seen` as `['abc.txt']`, because `_processOne` still processes segment 0 and overwrites the transcript.

- [ ] **Step 3: Rewrite the processing block of `_processOne`**

Keep everything around it — the `_processingId` claim, the usage scope, the `transcribing` write, and the clipboard / enrich / mirror tail. Replace the single-processor block with a loop over pending segments:

```dart
      // Re-read rather than trust the id: the item can be deleted in the await
      // above, and `firstWhere` would then throw out of a loop that runs
      // unawaited.
      final int index = _recordings.indexWhere(
        (Recording item) => item.id == id,
      );
      if (index < 0) return;
      final Recording recording = _recordings[index];

      // Deliberately outside the try below, and before any processor runs: a
      // video whose transcription fails is exactly the item the user most needs
      // to recognise in the queue, so the poster must not be collateral damage.
      await _extractPoster(recording.id);

      final List<CaptureSegment> pending = recording.segments
          .where((CaptureSegment segment) => segment.isPending)
          .toList();
      if (pending.isEmpty) {
        // Every segment already has text. Reached by a retry of a capture that
        // is not failed; re-sending would spend a provider call on text the app
        // already holds.
        _logSink.log('Nothing left to process.', recordingId: id);
        await _update(
          id,
          (Recording item) => item.copyWith(
            status: RecordingStatus.completed,
            clearError: true,
          ),
        );
        return;
      }

      String? failure;
      for (final CaptureSegment segment in pending) {
        if (_disposed) return;
        // Re-read at every step: the list is rewritten inside this loop, and
        // the capture can be deleted between two segments.
        if (!_recordings.any((Recording item) => item.id == id)) return;

        // Pinned per segment: a runtime swap (Models tab) during an await must
        // not redirect a job that already started, and two segments of one
        // capture can resolve to different processors.
        final Processor processor = _registry.forType(segment.type);
        _beginUsageJob(
          id,
          _stageFor(segment.type),
          audioSeconds: segment.durationMs > 0
              ? segment.durationMs / 1000
              : null,
        );
        String? text;
        try {
          text = await processor.process(segment);
        } catch (exception) {
          failure = exception.toString();
          await _updateSegment(
            id,
            segment.index,
            (CaptureSegment current) =>
                current.copyWith(error: exception.toString()),
          );
          _logSink.log(
            'Segment ${segment.index} failed: $exception',
            level: LogLevel.error,
            recordingId: id,
          );
        } finally {
          _endUsageJob();
        }
        if (text == null) continue;

        final String captured = text;
        await _update(
          id,
          (Recording item) => item.copyWith(
            segments: <CaptureSegment>[
              for (final CaptureSegment current in item.segments)
                if (current.index == segment.index)
                  current.copyWith(text: captured, clearError: true)
                else
                  current,
            ],
            // Accumulated, never recomputed from the segments: a rebuild would
            // undo a hand-edited transcript.
            transcript: appendSegmentText(item.transcript, captured),
          ),
        );
        _logSink.log(
          'Segment ${segment.index} processed · ${captured.length} characters',
          recordingId: id,
        );
      }

      if (failure != null) {
        await _update(
          id,
          (Recording item) =>
              item.copyWith(status: RecordingStatus.failed, error: failure),
        );
        return;
      }

      final int done = _recordings.indexWhere((Recording item) => item.id == id);
      if (done < 0) return;
      await _update(
        id,
        (Recording item) =>
            item.copyWith(status: RecordingStatus.completed, clearError: true),
      );
      final String transcript = _recordings[done].transcript ?? '';
```

The existing tail — `_copyToClipboard`, the `_beginUsageJob(id, UsageStage.enrichment)` / `_enrich` pair, `_mirrorToVault` — runs unchanged after that, on the accumulated `transcript`, exactly once per drain.

Add the helper beside `_update`:

```dart
  /// Rewrite one segment of one capture, through the same funnel every other
  /// mutation uses — which is what keeps the change history impossible to
  /// bypass by adding a new setter.
  Future<void> _updateSegment(
    String id,
    int index,
    CaptureSegment Function(CaptureSegment) transform,
  ) {
    return _update(
      id,
      (Recording item) => item.copyWith(
        segments: <CaptureSegment>[
          for (final CaptureSegment segment in item.segments)
            if (segment.index == index) transform(segment) else segment,
        ],
      ),
    );
  }
```

In `_extractPoster`, take the source from the first video segment, keeping the `<id>.thumb.jpg` destination and the `_postersInFlight` claim exactly as they are:

```dart
    final CaptureSegment? video = item.segments
        .where((CaptureSegment segment) => segment.type == CaptureType.video)
        .firstOrNull;
    if (video == null) return;
```

…then pass `File(video.filePath)` where `File(item.filePath)` was.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `flutter test test/capture_segment_processing_test.dart test/processing_queue_test.dart test/multimodal_test.dart test/ocr_test.dart test/enrichment_controller_test.dart`
Expected: PASS.

- [ ] **Step 5: Prove the accumulation test is not vacuous**

Copy the controller to the scratchpad first. Change `appendSegmentText(item.transcript, captured)` to `captured`, run `flutter test test/capture_segment_processing_test.dart`, and expect the third test to fail with `'second fragment'` instead of the corrected text. Copy the file back.

Do **not** use `git checkout -- <file>` to undo it: it reverts to HEAD and takes every other uncommitted change in that file with it.

- [ ] **Step 6: Commit**

```bash
git add lib/features/recordings/presentation/recordings_controller.dart test/capture_segment_processing_test.dart
git commit -m "feat(recordings): process only the segments that have no text

A capture can now hold several artifacts, and re-sending the ones that
already produced text is a provider call spent on text the app holds.
Each segment records its own text and its own error, so a fragment that
fails leaves the fragments that worked intact and the capture
retryable.

The transcript accumulates rather than being rebuilt from the segment
list: a rebuild would silently undo a hand-corrected transcript, and
nothing on screen would say so.

One deliberate consequence: retrying a capture whose segments all have
text is now a no-op rather than a re-transcription. The queue only
offers retry on a failed capture.

Refs #83"
```

---

### Task 6: The append entry points

**Files:**
- Modify: `lib/features/recordings/data/media_importer.dart`
- Modify: `lib/features/recordings/presentation/recordings_controller.dart` (`startRecording` :836, `stopRecording`, `addTextNote` :1129, `addUpload` :1186, `addImportedFile` :1229)
- Test: `test/capture_append_test.dart`

**Interfaces:**
- Consumes: `RecordingsRepository.createSegmentFile`, `Recording.nextSegmentIndex`, `_enqueueProcessing`, `_update`.
- Produces:
  - `Future<CaptureSegment> MediaImporter.importSegment({required String parentId, required int index, required CaptureType type, required File source, required DateTime createdAt, String? mimeType})`
  - `Future<void> RecordingsController.startRecording({String? appendTo})`
  - `Future<void> RecordingsController.addTextNote(String body, {String? appendTo})`
  - `Future<void> RecordingsController.addUpload(CaptureType type, {String? appendTo})`
  - `Future<void> RecordingsController.addImportedFile(File file, CaptureType type, {String? appendTo})`
  - `String? get RecordingsController.appendTargetId`

- [ ] **Step 1: Write the failing test**

```dart
// test/capture_append_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:augustyniak_capture/features/processing/domain/processor.dart';
import 'package:augustyniak_capture/features/processing/domain/processor_registry.dart';
import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_segment.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';

class _MemoryRepo extends RecordingsRepository {
  _MemoryRepo(this._dir, this.seed);
  final Directory _dir;
  final List<Recording> seed;

  @override
  Future<Directory> recordingsDirectory() async => _dir;
  @override
  Future<List<Recording>> loadAll() async => seed;
  @override
  Future<void> saveAll(List<Recording> recordings) async {}
}

class _RefusingRepo extends _MemoryRepo {
  _RefusingRepo(super.dir, super.seed);

  @override
  Future<File> createSegmentFile(String id, int index, String extension) async {
    throw const FileSystemException('disk full');
  }
}

class _EchoProcessor implements Processor {
  @override
  Future<String> process(CaptureSegment segment) =>
      File(segment.filePath).readAsString();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('capture-append');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<Recording> seedNote() async {
    final File file = File(p.join(dir.path, 'abc.txt'));
    await file.writeAsString('first fragment');
    return Recording(
      id: 'abc',
      filePath: file.path,
      createdAt: DateTime.utc(2026, 8, 28),
      durationMs: 0,
      sizeBytes: 14,
      status: RecordingStatus.completed,
      type: CaptureType.text,
      transcript: 'first fragment',
      title: 'Plan Q3',
      summary: 'A plan, as it stood before the addition.',
      tags: const <String>['budget'],
      isProcessedByUser: true,
      processedAt: DateTime.utc(2026, 8, 28),
      routes: <RouteRecord>[
        RouteRecord(
          at: DateTime.utc(2026, 8, 28, 9),
          kind: RouteKind.file,
          target: 'inbox.md',
        ),
      ],
    );
  }

  RecordingsController build(RecordingsRepository repository) {
    return RecordingsController(
      repository: repository,
      registry: ProcessorRegistry(<CaptureType, Processor>{
        CaptureType.text: _EchoProcessor(),
      }),
    );
  }

  test('appending a note adds a segment and re-opens the capture', () async {
    final RecordingsController controller = build(
      _MemoryRepo(dir, <Recording>[await seedNote()]),
    );
    await controller.initialize();

    await controller.addTextNote('second fragment', appendTo: 'abc');
    await controller.waitForProcessing();

    expect(
      controller.recordings,
      hasLength(1),
      reason: 'an append must not create a second row',
    );
    final Recording item = controller.recordings.single;
    expect(item.segments, hasLength(2));
    expect(p.basename(item.segments[1].filePath), 'abc-1.txt');
    expect(item.segments[1].type, CaptureType.text);
    expect(item.transcript, 'first fragment\n\nsecond fragment');
    expect(
      item.isProcessedByUser,
      isFalse,
      reason: 'the text that may already have been routed is now incomplete',
    );
    expect(item.title, 'Plan Q3', reason: 'field ownership is unchanged');
    expect(item.tags, contains('budget'), reason: 'a hand tag survives');
    expect(
      item.routes,
      hasLength(1),
      reason: 'the delivery happened; a fuller text does not un-send it',
    );
    expect(item.routes.single.target, 'inbox.md');
    expect(
      item.filePath,
      endsWith('abc.txt'),
      reason: 'top-level fields still describe segment 0',
    );
    controller.dispose();
  });

  test('enrichment re-runs over the fuller text and keeps the title', () async {
    // `_FakeEnrichment` is the fake in test/enrichment_controller_test.dart —
    // copy it verbatim rather than importing across suites, which is the house
    // pattern for hand-written fakes.
    final _FakeEnrichment enrichment = _FakeEnrichment(
      const EnrichmentResult(
        title: 'A title the model would like to impose',
        summary: 'Both fragments, summarised.',
        category: CaptureCategory.note,
        tags: <String>['plan'],
      ),
    );
    final RecordingsController controller = RecordingsController(
      repository: _MemoryRepo(dir, <Recording>[await seedNote()]),
      registry: ProcessorRegistry(<CaptureType, Processor>{
        CaptureType.text: _EchoProcessor(),
      }),
      enrichmentService: enrichment,
    );
    await controller.initialize();

    await controller.addTextNote('second fragment', appendTo: 'abc');
    await controller.waitForProcessing();

    final Recording item = controller.recordings.single;
    expect(enrichment.calls, 1, reason: 'enrichment runs once per drain');
    expect(
      enrichment.lastText,
      'first fragment\n\nsecond fragment',
      reason: 'the model sees the whole capture, not the new fragment alone',
    );
    expect(item.summary, 'Both fragments, summarised.');
    expect(
      item.title,
      'Plan Q3',
      reason: 'title is written only when blank — ownership is unchanged',
    );
    expect(item.tags, containsAll(<String>['budget', 'plan']));
    controller.dispose();
  });

  test('a fragment that cannot be written leaves the parent untouched', () async {
    final RecordingsController controller = build(
      _RefusingRepo(dir, <Recording>[await seedNote()]),
    );
    await controller.initialize();

    await controller.addTextNote('second fragment', appendTo: 'abc');
    await controller.waitForProcessing();

    final Recording item = controller.recordings.single;
    expect(item.hasStoredSegments, isFalse);
    expect(item.transcript, 'first fragment');
    expect(item.status, RecordingStatus.completed);
    expect(item.isProcessedByUser, isTrue);
    expect(controller.error, isNotNull);
    controller.dispose();
  });

  test('appending to an id that is gone is a no-op, not a new capture', () async {
    final RecordingsController controller = build(
      _MemoryRepo(dir, <Recording>[await seedNote()]),
    );
    await controller.initialize();

    await controller.addTextNote('orphan', appendTo: 'nope');
    await controller.waitForProcessing();

    expect(controller.recordings, hasLength(1));
    expect(controller.recordings.single.segments, hasLength(1));
    controller.dispose();
  });

  test('a second append lands at index 2', () async {
    final RecordingsController controller = build(
      _MemoryRepo(dir, <Recording>[await seedNote()]),
    );
    await controller.initialize();

    await controller.addTextNote('second', appendTo: 'abc');
    await controller.waitForProcessing();
    await controller.addTextNote('third', appendTo: 'abc');
    await controller.waitForProcessing();

    final Recording item = controller.recordings.single;
    expect(item.segments.map((CaptureSegment s) => s.index), <int>[0, 1, 2]);
    expect(p.basename(item.segments[2].filePath), 'abc-2.txt');
    expect(item.transcript, 'first fragment\n\nsecond\n\nthird');
    controller.dispose();
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `flutter test test/capture_append_test.dart`
Expected: FAIL — `No named parameter with the name 'appendTo'`.

- [ ] **Step 3: Add the importer's segment path**

```dart
  /// Copy a picked file in as a further segment of an existing capture.
  ///
  /// Same verify-then-return contract as [importFile]: the caller only touches
  /// the parent row after this returns, so a copy that fails costs nothing that
  /// already existed.
  Future<CaptureSegment> importSegment({
    required String parentId,
    required int index,
    required CaptureType type,
    required File source,
    required DateTime createdAt,
    String? mimeType,
  }) async {
    if (!await source.exists() || await source.length() == 0) {
      throw FileSystemException('Picked file is missing or empty.', source.path);
    }

    final String extension = RecordingsRepository.extensionFor(
      type,
      sourceMimeType: mimeType,
    );
    final File destination = await _repository.createSegmentFile(
      parentId,
      index,
      extension,
    );
    await source.copy(destination.path);

    final int sizeBytes = await destination.exists()
        ? await destination.length()
        : 0;
    if (sizeBytes == 0) {
      throw FileSystemException(
        'Imported fragment was not persisted correctly.',
        destination.path,
      );
    }

    return CaptureSegment(
      index: index,
      filePath: destination.path,
      type: type,
      sourceMimeType: mimeType,
      createdAt: createdAt,
      sizeBytes: sizeBytes,
    );
  }
```

- [ ] **Step 4: Add the controller's shared append step**

```dart
  /// The capture a fragment in progress will be appended to, or null for a
  /// capture that will stand on its own. Read by the capture screen so it can
  /// name what it is adding to.
  String? get appendTargetId => _appendTargetId;
  String? _appendTargetId;

  /// The index the fragment being recorded will occupy. Held rather than
  /// parsed back out of the file name, for the same reason `_activeId` is.
  int? _activeSegmentIndex;

  /// Attach an already-written, already-verified file to an existing capture.
  ///
  /// **The one rule this path adds to the capture lifecycle:** the parent row
  /// is not touched until the fragment's file has been verified, so a failed
  /// append leaves the capture byte for byte as it was. Everything after that
  /// is the familiar order — persist, then enqueue.
  Future<void> _attachSegment(String parentId, CaptureSegment segment) async {
    final int index = _recordings.indexWhere(
      (Recording item) => item.id == parentId,
    );
    if (index < 0) {
      // The capture was deleted while the fragment was being captured. There is
      // nothing to attach to, and inventing a row would file the fragment
      // somewhere the user never asked for.
      throw StateError('The capture this fragment belongs to is gone.');
    }

    await _update(
      parentId,
      (Recording item) => item.copyWith(
        segments: <CaptureSegment>[...item.segments, segment],
        // Back on the desk: the text that may already have been routed is now
        // incomplete, so the decision to send it again belongs to the user.
        // `routes` is deliberately untouched — the delivery happened.
        isProcessedByUser: false,
        clearProcessedAt: true,
      ),
      source: RevisionSource.user,
    );
    _logSink.log(
      'Fragment ${segment.index} added · ${segment.type.name} · '
      '${segment.sizeBytes} B',
      recordingId: parentId,
    );
    unawaited(_computeContentHash(parentId, segmentIndex: segment.index));
    await _enqueueProcessing(parentId);
  }

  /// The index the next fragment of [parentId] should take, or null when that
  /// capture is gone.
  int? _nextSegmentIndexFor(String parentId) {
    final int index = _recordings.indexWhere(
      (Recording item) => item.id == parentId,
    );
    return index < 0 ? null : _recordings[index].nextSegmentIndex;
  }
```

**Add the `segmentIndex` parameter to `_computeContentHash` in this task**, as the one-line signature change it is:

```dart
  Future<void> _computeContentHash(String id, {int segmentIndex = 0}) async {
```

…hashing `_recordings[index].segments.firstWhere((s) => s.index == segmentIndex).filePath`, writing through `_updateSegment`, and additionally setting the row-level `contentHash` when `segmentIndex == 0`. Task 7 then extends the *backfill* to enumerate segments and keys `_hashesInFlight` per segment. Splitting it that way keeps this task's append path complete on its own rather than depending on a task that has not run.

The test file needs three more imports for the fake and the seeded row: `capture_category.dart`, `route_record.dart`, and the enrichment service and result from `features/enrichment/`.

- [ ] **Step 5: Thread `appendTo` through the four entry points**

Each keeps its existing `_isBusy` guard, its existing verification and its existing `finally`. The only branch is where the verified file goes.

`addTextNote(String body, {String? appendTo})` — at the top of the existing `try`, leaving the standalone-note path below it untouched:

```dart
      if (appendTo != null) {
        final int? next = _nextSegmentIndexFor(appendTo);
        if (next == null) {
          throw StateError('The capture this note belongs to is gone.');
        }
        final File file = await _repository.createSegmentFile(
          appendTo,
          next,
          'txt',
        );
        await file.writeAsString(trimmed, flush: true);
        final int sizeBytes = await file.exists() ? await file.length() : 0;
        if (sizeBytes == 0) {
          throw FileSystemException(
            'Note fragment was not persisted correctly.',
            file.path,
          );
        }
        await _attachSegment(
          appendTo,
          CaptureSegment(
            index: next,
            filePath: file.path,
            type: CaptureType.text,
            sourceMimeType: 'text/plain',
            createdAt: DateTime.now(),
            sizeBytes: sizeBytes,
          ),
        );
        return;
      }
```

`addImportedFile(File file, CaptureType type, {String? appendTo})` and `addUpload(CaptureType type, {String? appendTo})` take the same shape, calling `_importer.importSegment(...)` and then `_attachSegment`. `addUpload` keeps holding `_isBusy` across the picker await exactly as it does now.

`startRecording({String? appendTo})` stores `_appendTargetId = appendTo` and `_activeSegmentIndex = _nextSegmentIndexFor(appendTo)` beside `_recordingProjectId`, and creates its file through `createSegmentFile(appendTo, _activeSegmentIndex!, 'm4a')` when appending. In `stopRecording`, after the existing `sizeBytes == 0` check and before the `Recording` is built:

```dart
      final String? parentId = _appendTargetId;
      final int? segmentIndex = _activeSegmentIndex;
      if (parentId != null && segmentIndex != null) {
        await _attachSegment(
          parentId,
          CaptureSegment(
            index: segmentIndex,
            filePath: path,
            type: CaptureType.audioRecording,
            createdAt: DateTime.now(),
            durationMs: _stopwatch.elapsedMilliseconds,
            sizeBytes: sizeBytes,
          ),
        );
        return;
      }
```

Clear `_appendTargetId` and `_activeSegmentIndex` in the same `finally` that clears `_recordingProjectId`.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `flutter test test/capture_append_test.dart test/media_importer_test.dart test/failed_save_test.dart test/capture_session_test.dart`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/features/recordings/data/media_importer.dart lib/features/recordings/presentation/recordings_controller.dart test/capture_append_test.dart
git commit -m "feat(recordings): append a fragment to an existing capture

Three entry points — record, type, pick a file — can now attach their
verified artifact to a capture instead of creating one. They keep the
capture lifecycle's order and the _isBusy lock, and add the one rule
this path needs: the parent row is not touched until the fragment's
file exists with length > 0, so a failed append leaves the capture byte
for byte as it was.

An append puts a finished capture back on the desk. routes is left
alone: the delivery happened, and what returns to the user is the
decision to send the fuller text again.

Refs #83"
```

---

### Task 7: Content hashes per segment

**Files:**
- Modify: `lib/features/recordings/presentation/recordings_controller.dart` (`_computeContentHash` :679, `_hashSource`, `_backfillContentHashes`, `_hashInBatch`)
- Test: extend `test/content_hash_test.dart`

**Interfaces:**
- Consumes: `_computeContentHash(String id, {int segmentIndex})` from Task 6, `Recording.segments`, `_updateSegment` from Task 5.
- Produces: `_backfillContentHashes` / `_hashInBatch` enumerating `(id, segmentIndex)` pairs for every segment with a null hash; `_hashesInFlight` keyed on `'$id#$segmentIndex'`.

- [ ] **Step 1: Write the failing test**

Add to `test/content_hash_test.dart`. `_Repo` and `_legacy` are the fakes already in that file; `dir` is the temp directory its `setUp` creates — match the local names it uses.

```dart
  test('the backfill hashes every segment and leaves the row hash alone', () async {
    final File first = File(p.join(dir.path, 'abc.m4a'))
      ..writeAsStringSync('first bytes');
    final File second = File(p.join(dir.path, 'abc-1.m4a'))
      ..writeAsStringSync('second bytes');

    const String rowHash = 'c' * 64;
    final Recording seeded = Recording(
      id: 'abc',
      filePath: first.path,
      createdAt: DateTime.utc(2026, 8, 28),
      durationMs: 1000,
      sizeBytes: first.lengthSync(),
      contentHash: rowHash,
      status: RecordingStatus.completed,
      type: CaptureType.audioRecording,
      transcript: 'first fragment',
      segments: <CaptureSegment>[
        CaptureSegment(
          index: 0,
          filePath: first.path,
          type: CaptureType.audioRecording,
          createdAt: DateTime.utc(2026, 8, 28),
          sizeBytes: first.lengthSync(),
          contentHash: rowHash,
          text: 'first fragment',
        ),
        CaptureSegment(
          index: 1,
          filePath: second.path,
          type: CaptureType.audioRecording,
          createdAt: DateTime.utc(2026, 8, 28),
          sizeBytes: second.lengthSync(),
          text: 'second fragment',
        ),
      ],
    );

    final _Repo repository = _Repo(dir, <Recording>[seeded]);
    final RecordingsController controller = RecordingsController(
      repository: repository,
      transcriptionService: const DisabledTranscriptionService(),
    );
    await controller.initialize();
    await controller.waitForProcessing();

    final Recording item = controller.recordings.single;
    expect(item.segments[1].contentHash, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(
      item.segments[1].contentHash,
      isNot(item.segments[0].contentHash),
      reason: 'different bytes, different hash',
    );
    expect(
      item.contentHash,
      rowHash,
      reason: 'the row hash describes segment 0 and must survive an append',
    );
    controller.dispose();
  });
```

Match the `RecordingsController(...)` argument list to the one the other tests in this file already use — the constructor's parameters have moved before.

- [ ] **Step 2: Run the test to verify it fails**

Run: `flutter test test/content_hash_test.dart`
Expected: FAIL — segment 1's hash stays null.

- [ ] **Step 3: Write the implementation**

- `_hashSource(String id, {int segmentIndex = 0})` hashes that segment's path. (`_computeContentHash` already took the parameter in Task 6; this task is the backfill and the keying.)
- `_backfillContentHashes` / `_hashInBatch` enumerate `(id, segment.index)` pairs for every segment with a null hash, rather than only rows with a null `contentHash`.
- `_hashesInFlight` keys on `'$id#$segmentIndex'`, so two segments of one capture do not shut each other out. `waitForProcessing` already awaits that set.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `flutter test test/content_hash_test.dart test/capture_append_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/features/recordings/presentation/recordings_controller.dart test/content_hash_test.dart
git commit -m "feat(recordings): hash each segment, never across them

A hash recomputed over every segment would change each time a fragment
is appended, so an archive taken yesterday would stop recognising its
own capture and restore a duplicate of it. Each segment carries the
hash of its own bytes; the row-level contentHash keeps describing
segment 0, which is what the archive compares.

Refs #83"
```

---

### Task 8: The archive carries every segment

**Files:**
- Modify: `lib/features/backup/data/zip_capture_archive.dart` (`_planImport` around :414, `_restoreSources` around :444, `_relocate` around :572)
- Test: extend `test/backup_archive_test.dart`

**Interfaces:**
- Consumes: `Recording.segments`, `Recording.hasStoredSegments`.
- Produces: an import that requires every segment member to be present and conventionally named, extracts each through the existing `.importing` staging, and re-roots each path in `_relocate`.

Export needs no change: it enumerates the recordings **directory** and `_isPayload` already accepts `<id>-1.m4a`. Verify that in Step 1 rather than assuming it.

- [ ] **Step 1: Write the failing tests**

Add to `test/backup_archive_test.dart`. `source`, `target`, `scratch`, `archiveFor`, `repositoryFor` and `seed` are the helpers already declared in its `main()`; add this local builder beside `capture(...)` and then the three tests.

```dart
  /// A capture holding two source artifacts, the way an appended fragment
  /// leaves it: `<id>.m4a` plus `<id>-1.txt`.
  Recording twoSegmentCapture(String id, {String? contentHash}) => Recording(
    id: id,
    filePath: p.join(source.path, '$id.m4a'),
    createdAt: DateTime(2026, 8, 28, 12),
    durationMs: 1000,
    sizeBytes: 12,
    contentHash: contentHash,
    type: CaptureType.audioRecording,
    status: RecordingStatus.completed,
    transcript: 'first fragment\n\nsecond fragment',
    title: 'Title $id',
    segments: <CaptureSegment>[
      CaptureSegment(
        index: 0,
        filePath: p.join(source.path, '$id.m4a'),
        type: CaptureType.audioRecording,
        createdAt: DateTime(2026, 8, 28, 12),
        durationMs: 1000,
        sizeBytes: 12,
        contentHash: contentHash,
        text: 'first fragment',
      ),
      CaptureSegment(
        index: 1,
        filePath: p.join(source.path, '$id-1.txt'),
        type: CaptureType.text,
        createdAt: DateTime(2026, 8, 28, 12, 5),
        sizeBytes: 12,
        text: 'second fragment',
      ),
    ],
  );

  test('a two-segment capture survives an export and an import', () async {
    await seed(source, <Recording>[twoSegmentCapture('abc')]);
    // `seed` writes one file per row; the fragment needs writing too.
    await File(p.join(source.path, 'abc-1.txt')).writeAsString('fragment-abc');

    final File zip = File(p.join(scratch.path, 'capture.zip'));
    await archiveFor(source).export(zip);
    final RestoreSummary summary = await archiveFor(target).import(zip);

    expect(
      await File(p.join(target.path, 'abc.m4a')).readAsString(),
      'audio-abc',
    );
    expect(
      await File(p.join(target.path, 'abc-1.txt')).readAsString(),
      'fragment-abc',
    );

    final Recording restored = (await repositoryFor(target).loadAll()).single;
    expect(restored.segments, hasLength(2));
    for (final CaptureSegment segment in restored.segments) {
      expect(
        segment.filePath,
        startsWith(target.path),
        reason: 'an absolute path from another container points nowhere here',
      );
    }
    expect(restored.transcript, 'first fragment\n\nsecond fragment');
    expect(summary.filesRestored, 2);
  });

  test('a missing segment member refuses the row rather than half-importing it', () async {
    await seed(source, <Recording>[twoSegmentCapture('abc')]);
    await File(p.join(source.path, 'abc-1.txt')).writeAsString('fragment-abc');

    final File zip = File(p.join(scratch.path, 'capture.zip'));
    await archiveFor(source).export(zip);
    // Rebuild the archive without the fragment, leaving the manifest and the
    // index describing a capture whose second source is not there.
    await stripMember(zip, 'abc-1.txt');

    final RestoreSummary summary = await archiveFor(target).import(zip);

    expect(summary.unreadable, 1);
    expect(summary.additions, isEmpty);
    expect(
      await File(p.join(target.path, 'abc.m4a')).exists(),
      isFalse,
      reason: 'a row with a missing source must not be half-applied',
    );
  });

  test('re-importing the same archive counts it alreadyPresent', () async {
    await seed(source, <Recording>[twoSegmentCapture('abc', contentHash: 'd' * 64)]);
    await File(p.join(source.path, 'abc-1.txt')).writeAsString('fragment-abc');

    final File zip = File(p.join(scratch.path, 'capture.zip'));
    await archiveFor(source).export(zip);
    await archiveFor(target).import(zip);
    final RestoreSummary second = await archiveFor(target).import(zip);

    expect(second.alreadyPresent, 1);
    expect(
      second.matchedByIdAlone,
      0,
      reason: 'the row hash describes segment 0 and is stable across appends',
    );
  });
```

`stripMember` is a local helper this file does not have yet — add it beside `seed`:

```dart
  /// Rewrite a zip without one member, leaving every other member and the
  /// manifest untouched.
  Future<void> stripMember(File zip, String name) async {
    final Archive original = ZipDecoder().decodeBytes(await zip.readAsBytes());
    final Archive stripped = Archive();
    for (final ArchiveFile member in original) {
      if (member.name == name) continue;
      stripped.addFile(member);
    }
    await zip.writeAsBytes(ZipEncoder().encode(stripped)!);
  }
```

Match `export` / `import` / `RestoreSummary`'s real names and shapes to what `CaptureArchive` declares — check `lib/features/backup/domain/capture_archive.dart` before writing, since the existing tests in this file already call them and are the reference.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/backup_archive_test.dart`
Expected: FAIL — the restored row has one segment and `abc-1.txt` is absent.

- [ ] **Step 3: Write the implementation**

In `_planImport`, replace the single `sourceName` check with a loop that requires every segment:

```dart
      bool everyMemberPresent = true;
      for (final CaptureSegment segment in incoming.segments) {
        final String name = p.basename(segment.filePath);
        final ArchiveFile? member = archive.findFile(name);
        final String stem = p.basenameWithoutExtension(name);
        final bool conventionalName =
            (stem == incoming.id ||
                stem == '${incoming.id}-${segment.index}') &&
            _isPayload(name) &&
            !indexFiles.contains(name) &&
            !journalFiles.contains(name);
        if (!conventionalName ||
            member == null ||
            !member.isFile ||
            member.isSymbolicLink ||
            member.size <= 0) {
          everyMemberPresent = false;
          break;
        }
      }
      if (!everyMemberPresent) {
        plan.unreadable++;
        continue;
      }
```

In `_restoreSources`, iterate `item.segments` and run the existing staging-and-rename block per member; a row counts as restored only when every member landed. The `.importing` staging file is deleted on **every** failure path, as it is today.

In `_relocate`, re-root the list as well as the top-level path:

```dart
      segments: recording.hasStoredSegments
          ? <CaptureSegment>[
              for (final CaptureSegment segment in recording.segments)
                CaptureSegment(
                  index: segment.index,
                  filePath: p.join(
                    directory.path,
                    p.basename(segment.filePath),
                  ),
                  type: segment.type,
                  sourceMimeType: segment.sourceMimeType,
                  createdAt: segment.createdAt,
                  durationMs: segment.durationMs,
                  sizeBytes: segment.sizeBytes,
                  contentHash: segment.contentHash,
                  text: segment.text,
                  error: segment.error,
                ),
            ]
          : null,
```

Rebuilt field by field rather than through `copyWith`, for the reason `_relocate`'s own doc comment gives: this is a re-pointing at the same bytes in a new home, not a mutation, and widening `copyWith` would hand every caller a way to detach a row from its files.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `flutter test test/backup_archive_test.dart test/backup_coordinator_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/features/backup/data/zip_capture_archive.dart test/backup_archive_test.dart
git commit -m "feat(backup): archive and restore every segment of a capture

Export already carried the files — it enumerates the directory — while
import mapped one row to one member, so a restored capture kept its
first fragment and pointed at nothing for the rest. A row is now
refused unless every member is present, which keeps the existing rule
that a failed import stays retryable rather than half-applied.

Refs #83"
```

---

### Task 9: Sync re-roots every segment path

**Files:**
- Modify: `lib/core/sync/sync_path_policy.dart`
- Test: extend the existing sync path suite. Find it with `ls test | grep -i sync`; create `test/sync_path_policy_test.dart` if there is none.

**Interfaces:**
- Consumes: nothing new.
- Produces: `SyncPathPolicy.sanitizePayload` re-rooting every entry of `payload['segments']`, dropping a segment whose name is unusable, and dropping the whole row when segment 0 is unusable (which the existing `filePath` check already covers).

- [ ] **Step 1: Write the failing test**

```dart
  test('every segment path is re-rooted, not just the first', () {
    final Map<String, dynamic>? clean = SyncPathPolicy.sanitizePayload(
      <String, dynamic>{
        'filePath': '/other/device/recordings/abc.m4a',
        'thumbPath': null,
        'segments': <dynamic>[
          <String, dynamic>{
            'index': 0,
            'filePath': '/other/device/recordings/abc.m4a',
          },
          <String, dynamic>{
            'index': 1,
            'filePath': '/other/device/recordings/abc-1.m4a',
          },
        ],
      },
      recordingsDirectory: '/local/recordings',
    );

    final List<dynamic> segments = clean!['segments'] as List<dynamic>;
    expect(
      (segments[0] as Map<String, dynamic>)['filePath'],
      '/local/recordings/abc.m4a',
    );
    expect(
      (segments[1] as Map<String, dynamic>)['filePath'],
      '/local/recordings/abc-1.m4a',
    );
  });

  test('a segment with an unusable name is dropped, not kept', () {
    final Map<String, dynamic>? clean = SyncPathPolicy.sanitizePayload(
      <String, dynamic>{
        'filePath': '/other/abc.m4a',
        'segments': <dynamic>[
          <String, dynamic>{'index': 0, 'filePath': '/other/abc.m4a'},
          <String, dynamic>{'index': 1, 'filePath': '..'},
        ],
      },
      recordingsDirectory: '/local/recordings',
    );

    expect(clean!['segments'] as List<dynamic>, hasLength(1));
  });
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `flutter test test/sync_path_policy_test.dart`
Expected: FAIL — `segments` comes back with the remote paths untouched.

- [ ] **Step 3: Write the implementation**

In `sanitizePayload`, after the poster block and before the `artifacts` line:

```dart
    // The payload is the half `loadAll` prefers, and every segment path is
    // acted on exactly as `filePath` is: deleted, opened, copied into the
    // vault. A segment whose name cannot be trusted is dropped, like a poster;
    // the row itself only falls when segment 0 is unusable, which the `source`
    // check above already covers.
    final Object? rawSegments = payload['segments'];
    if (rawSegments is List) {
      final List<Map<String, dynamic>> segments = <Map<String, dynamic>>[];
      for (final Object? entry in rawSegments) {
        if (entry is! Map<String, dynamic>) continue;
        final String? name = localFileName(entry['filePath']);
        if (name == null) continue;
        segments.add(<String, dynamic>{
          ...entry,
          'filePath': p.join(recordingsDirectory, name),
        });
      }
      clean['segments'] = segments;
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `flutter test test/sync_path_policy_test.dart test/turso_sync_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/core/sync/sync_path_policy.dart test/sync_path_policy_test.dart
git commit -m "fix(sync): re-root every segment path in a pulled payload

The payload is the half loadAll prefers, and each segment path is acted
on exactly as filePath is — deleted, opened, copied into the vault. A
pulled capture would otherwise arrive with its first fragment in place
and the rest pointing into another device's container.

Refs #83"
```

---

### Task 10: The vault mirrors every source

**Files:**
- Modify: `lib/features/recordings/domain/note_vault.dart` (`VaultNote.sourcePath` becomes `sourcePaths`), `lib/features/recordings/data/markdown_note_vault.dart` (:211, :248, :265-280), `lib/features/recordings/presentation/recordings_controller.dart` (`_mirrorOne` :2249)
- Test: extend `test/note_vault_test.dart`

**Interfaces:**
- Consumes: `Recording.segments`.
- Produces: `VaultNote.sourcePaths` as a `List<String>` defaulting to `const <String>[]`; the mirror copying each into `attachments/` and embedding one `![[...]]` per file, in segment order; the `source:` front-matter key naming segment 0 as before.

- [ ] **Step 1: Write the failing tests**

In `test/note_vault_test.dart`, change the local `note({...})` builder's `String? sourcePath` parameter to `List<String> sourcePaths = const <String>[]` and pass it through, then add:

```dart
  test('every segment source is attached once', () async {
    final File audio = File(p.join(vault.parent.path, 'abc.m4a'))
      ..writeAsStringSync('audio bytes');
    final File image = File(p.join(vault.parent.path, 'abc-1.png'))
      ..writeAsStringSync('image bytes');

    final MarkdownNoteVault mirror = build();
    await mirror.mirror(
      note(sourcePaths: <String>[audio.path, image.path]),
    );

    final Directory attachments = Directory(
      p.join(notesDir().path, VaultDefaults.attachments),
    );
    expect(
      File(p.join(attachments.path, 'abc.m4a')).existsSync(),
      isTrue,
    );
    expect(
      File(p.join(attachments.path, 'abc-1.png')).existsSync(),
      isTrue,
    );

    final String body = soleNote().readAsStringSync();
    expect(
      body.indexOf('![[${VaultDefaults.attachments}/abc.m4a]]'),
      lessThan(body.indexOf('![[${VaultDefaults.attachments}/abc-1.png]]')),
      reason: 'attachments follow segment order',
    );

    final VaultWrite again = await mirror.mirror(
      note(sourcePaths: <String>[audio.path, image.path]),
    );
    expect(
      again.outcome,
      VaultOutcome.unchanged,
      reason: 'a no-op write would bump the mtime on every pipeline tick',
    );
  });

  test('a note with no sources attaches nothing', () async {
    await build().mirror(note(type: CaptureType.text));

    expect(
      Directory(p.join(notesDir().path, VaultDefaults.attachments)).existsSync(),
      isFalse,
      reason: 'a text segment is the body printed above, not an attachment',
    );
  });
```

`vault.parent.path` is used as a scratch location for the source files so they sit outside the vault directory, the way a recordings directory does. If this suite's `setUp` already creates a separate scratch directory, use that instead.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/note_vault_test.dart`
Expected: FAIL — `VaultNote` has no `sourcePaths`.

- [ ] **Step 3: Write the implementation**

Replace `final String? sourcePath;` with `final List<String> sourcePaths;`, keep the `source:` front-matter key reading `sourcePaths.firstOrNull`, and turn the single-attachment block into a loop writing one `![[...]]` per copied file. The existing skip rule stays: a copy is skipped when the destination already matches in length, since a source is immutable once captured.

In `_mirrorOne`, build the list from the segments, dropping text sources:

```dart
        sourcePaths: <String>[
          for (final CaptureSegment segment in item.segments)
            if (segment.type != CaptureType.text) segment.filePath,
        ],
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `flutter test test/note_vault_test.dart test/vault_mirror_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/features/recordings test/note_vault_test.dart
git commit -m "feat(recordings): attach every segment source to the vault note

The mirror is a second copy of the capture, so a note carrying only the
first fragment's audio is a copy of half of it. Each source is attached
once, in segment order; a text segment still attaches nothing, because
it is the body printed above.

Refs #83"
```

---

### Task 11: The queue can add a fragment

**Files:**
- Modify: `lib/features/recordings/presentation/recording_editor.dart` (add the `FRAGMENTS` section and the `+ FRAGMENT` control), `lib/features/recordings/presentation/queue_tab.dart` (the `RecordingEditor(...)` call site at :811), `lib/features/recordings/presentation/recordings_page.dart` (wire the callbacks), `lib/features/recordings/presentation/recording_view.dart` (header naming the capture being appended to)
- Test: `test/widget/capture_append_ui_test.dart`

**Interfaces:**
- Consumes: `RecordingsController.startRecording(appendTo:)`, `addTextNote(body, appendTo:)`, `addUpload(type, appendTo:)`, `appendTargetId`, `Recording.segments`, `Recording.totalDurationMs`, `Recording.totalSizeBytes`.
- Produces: on `RecordingEditor` — `final VoidCallback? onAppendRecording; final VoidCallback? onAppendNote; final ValueChanged<CaptureType>? onAppendUpload;`. All three nullable, so a host with no append path renders the editor exactly as before.

- [ ] **Step 1: Write the failing test**

The editor is mounted directly rather than through the shell: it is a widget with plain callbacks, so nothing here needs a controller, a repository or a platform channel.

```dart
// test/widget/capture_append_ui_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_segment.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recording_editor.dart';

void main() {
  final DateTime at = DateTime.utc(2026, 8, 28, 10);

  Recording twoSegments() => Recording(
    id: 'abc',
    filePath: '/tmp/recordings/abc.m4a',
    createdAt: at,
    durationMs: 5000,
    sizeBytes: 2048,
    status: RecordingStatus.completed,
    type: CaptureType.audioRecording,
    transcript: 'first fragment\n\nsecond fragment',
    segments: <CaptureSegment>[
      CaptureSegment(
        index: 0,
        filePath: '/tmp/recordings/abc.m4a',
        type: CaptureType.audioRecording,
        createdAt: at,
        durationMs: 5000,
        sizeBytes: 2048,
        text: 'first fragment',
      ),
      CaptureSegment(
        index: 1,
        filePath: '/tmp/recordings/abc-1.txt',
        type: CaptureType.text,
        createdAt: at,
        sizeBytes: 12,
        text: 'second fragment',
      ),
    ],
  );

  Future<void> mount(
    WidgetTester tester,
    Recording recording, {
    VoidCallback? onAppendNote,
    VoidCallback? onAppendRecording,
    ValueChanged<CaptureType>? onAppendUpload,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: RecordingEditor(
              recording: recording,
              revisions: const <RecordingRevision>[],
              tagSuggestions: const <String>[],
              onTitleChanged: (_) {},
              onTextChanged: (_) {},
              onCategoryChanged: (_) {},
              onTagsChanged: (_) {},
              onDone: () {},
              onAppendNote: onAppendNote,
              onAppendRecording: onAppendRecording,
              onAppendUpload: onAppendUpload,
            ),
          ),
        ),
      ),
    );
    // Never pumpAndSettle here: the editor holds text fields and the card can
    // hold a PulseDot, both of which schedule frames forever.
    await tester.pump(const Duration(milliseconds: 250));
  }

  testWidgets('a multi-segment capture lists its fragments', (
    WidgetTester tester,
  ) async {
    await mount(tester, twoSegments(), onAppendNote: () {});

    expect(find.text('FRAGMENTS'), findsOneWidget);
    expect(find.textContaining('second fragment'), findsWidgets);
  });

  testWidgets('the note action fires once', (WidgetTester tester) async {
    int calls = 0;
    await mount(tester, twoSegments(), onAppendNote: () => calls++);

    await tester.ensureVisible(find.text('+ FRAGMENT'));
    await tester.pump();
    await tester.tap(find.text('+ FRAGMENT'));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text('NOTE'));
    await tester.pump(const Duration(milliseconds: 250));

    expect(calls, 1);
  });

  testWidgets('no append callbacks means no append control', (
    WidgetTester tester,
  ) async {
    await mount(tester, twoSegments());

    expect(find.text('+ FRAGMENT'), findsNothing);
  });
}
```

Fill in `RecordingEditor`'s remaining required parameters — the class has grown several (`usageEvents`, `storagePrice`, `projects`) — by copying the argument list from the existing editor test in `test/widget/`, and match the menu's real labels if they differ from `NOTE`.

Rules this suite must follow, all of them already paid for in this repo:

- Never `pumpAndSettle` a screen holding a `PulseDot`, a `ScanLine` or a focused `TextField` — pump explicit frames.
- The editor's footer is below the fold: pump past the row's 220 ms `AnimatedSize` **first**, then `ensureVisible`, then tap. Scrolling before the growth lands aims at a box that is still card-sized.
- `find.bySemanticsLabel` compares the whole merged label; a button whose child spells out a shorter word needs `excludeSemantics: true`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `flutter test test/widget/capture_append_ui_test.dart`
Expected: FAIL — no `FRAGMENTS` section is found.

- [ ] **Step 3: Write the implementation**

- A `FRAGMENTS` `SectionHeader` in `RecordingEditor`, above `RevisionHistorySection`, listing `recording.segments`: index, a `ConsoleIconTile` for the type, and the duration or size, all from `ui_kit.dart`. Rendered only when `recording.segments.length > 1`, so a single-source capture looks exactly as it does today.
- A `+ FRAGMENT` `ConsoleChip` beside it, shown only when at least one callback is non-null, opening the same three-action menu the capture dock uses.
- No per-segment delete control — see the spec's section 9 for why.
- The card's verification footer reads `totalSizeBytes` and `totalDurationMs`, so a multi-segment capture reports what it actually holds.
- In `queue_tab.dart`, pass the three callbacks through from the shell.
- In `recordings_page.dart`, wire them to the controller with `appendTo: recording.id`, and switch to tab 0 for a recording append exactly as the shortcut path does.
- In `recording_view.dart`, when `controller.appendTargetId != null`, render `ADDING TO <name>` in the header, using `displayNameFor` so the screen and the row can never disagree.
- Every widget that paints a palette colour keeps a **non-const** constructor.

- [ ] **Step 4: Run the tests and the analyzer**

Run: `flutter analyze && flutter test`
Expected: PASS, analyze clean.

- [ ] **Step 5: Look at it**

Run the app (`flutter run -d linux`, or `flutter build macos --release` and open the bundle). Record a note, append a recording to it, append a picked image, and confirm: the queue keeps one row, the transcript grows, the `FRAGMENTS` list matches what was added, and the capture comes back under the DESK filter. A green suite cannot see a layout that is wrong — this step is the only thing that can.

- [ ] **Step 6: Commit**

```bash
git add lib/features/recordings/presentation test/widget/capture_append_ui_test.dart
git commit -m "feat(recordings): add a fragment from the queue

The editor grows a FRAGMENTS list and a + FRAGMENT control offering the
same three actions as the capture dock, and the capture screen says
which note it is adding to. All three callbacks are nullable, so a host
with no append path renders the editor exactly as before.

Refs #83"
```

---

### Task 12: Write down what a capture is now

**Files:**
- Modify: `CLAUDE.md` (capture lifecycle, controller invariants, the SQLite paragraph, the `Recording` section)
- Modify: `docs/architecture/backup.md`, `docs/architecture/enrichment.md` (the vault paragraph)
- Modify: `docs/superpowers/specs/2026-08-28-capture-segments-design.md` — flip `Status: **proposed**` to `Status: **shipped**`

**Interfaces:** none — documentation only.

- [ ] **Step 1: Add the invariants to `CLAUDE.md`**

Beside the capture-lifecycle list, state: a capture may hold several segments; the segment is the unit of processing and of retry; the top-level source fields describe segment 0 and are the archive's deduplication contract; `transcript` accumulates and is never recomputed; an append does not touch the parent row until the fragment's file is verified; `findOrphans` claims files by name, because an id-based match re-adopts every fragment one launch later.

In the SQLite paragraph, add `segments` beside `transcript` in the list of fields that live only in `json_payload` and are therefore lost by a row rebuilt from the columns.

Where `retryTranscription` is described, record the behaviour change: a retry re-runs only pending segments, so retrying a capture whose segments all have text is a no-op.

- [ ] **Step 2: Run the whole suite and the analyzer**

Run: `flutter analyze && flutter test`
Expected: PASS, everything green.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md docs
git commit -m "docs: record what a capture is once it can hold fragments

Refs #83"
```

- [ ] **Step 4: Review, then open the pull request**

Spawn a reviewer on the full branch diff before pushing — this branch changes the persistence format, the orphan sweep and the archive, and no PR here opens on an unreviewed diff.

```bash
git push -u origin feat/83-capture-segments
gh pr create --title "feat: append further fragments to an existing capture" --body "Closes #83

Implements docs/superpowers/specs/2026-08-28-capture-segments-design.md."
```
