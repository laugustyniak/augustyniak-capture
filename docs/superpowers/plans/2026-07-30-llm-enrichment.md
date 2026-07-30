# LLM Enrichment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After a processor produces text, send it to a configurable OpenAI-compatible chat model and store a title, category, summary and tags on the item.

**Architecture:** A new `features/enrichment/` mirrors `features/transcription/` exactly — an interface, a disabled default, and one HTTP impl. `RecordingsController` calls it as a best-effort side-car *after* the item is already persisted as `completed`, so a failure can never cost a capture. Configuration reuses `ProviderProfile` with a new `kind` discriminator rather than a parallel type.

**Tech Stack:** Dart/Flutter, `http` (already a dependency), plain `ChangeNotifier`, no DI or state-management package, hand-written fakes in tests.

**Spec:** `docs/superpowers/specs/2026-07-30-llm-enrichment-design.md`

## Global Constraints

- Work happens in the worktree `.worktrees/feat-21-llm-enrichment` on branch `feat/21-llm-enrichment` (issue #21).
- `flutter analyze && flutter test` must pass before every commit. There is no server-side CI; this is the only gate.
- Tests are **pure Dart** unless the code under test crosses a platform channel. Widget tests live in `test/widget/`.
- User-facing strings are **English** (CLAUDE.md: the design pass translated them; do not reintroduce Polish), and so are identifiers, comments and `LogSink` messages.
- Every raw hex colour belongs in `Console` (`lib/app/ui_kit.dart`). Reuse `StatusPill`, `ConsoleChip`, `SectionHeader`, `ConsoleCard`, `InfoRow` rather than re-declaring them.
- No snackbars; no dialogs except `confirmDestructive()`.
- Every `fromJson` stays backward compatible: a new field defaults when absent, and every task that adds one also adds a legacy-JSON test.
- Enrichment is best-effort: it runs **after** the item is persisted as `completed`, it swallows every error into `LogSink`, and it never changes `status`.
- A user-set `title` is never overwritten.

---

### Task 1: `CaptureCategory` enum

**Files:**
- Create: `lib/features/recordings/domain/capture_category.dart`
- Test: `test/enrichment_test.dart`

**Interfaces:**
- Consumes: nothing
- Produces: `enum CaptureCategory {note, task, agentTask, idea, meetingNote, researchLead, capture}`, `static CaptureCategory fromName(String?)`, `String get label`

- [ ] **Step 1: Write the failing test**

```dart
// test/enrichment_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_notes_phase1/features/recordings/domain/capture_category.dart';

void main() {
  group('CaptureCategory', () {
    test('null and unknown names both degrade to capture', () {
      expect(CaptureCategory.fromName(null), CaptureCategory.capture);
      expect(CaptureCategory.fromName('journal'), CaptureCategory.capture);
      expect(CaptureCategory.fromName(''), CaptureCategory.capture);
    });

    test('known names round-trip', () {
      for (final CaptureCategory value in CaptureCategory.values) {
        expect(CaptureCategory.fromName(value.name), value);
      }
    });

    test('every category has a non-empty Polish label', () {
      for (final CaptureCategory value in CaptureCategory.values) {
        expect(value.label.trim(), isNotEmpty);
      }
    });
  });
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `flutter test test/enrichment_test.dart`
Expected: FAIL — `capture_category.dart` does not exist.

- [ ] **Step 3: Write the enum**

```dart
// lib/features/recordings/domain/capture_category.dart

/// What an item *is*, expressed as the destination it will eventually be routed
/// to — Obsidian, Todoist, an agent queue — rather than as a topic. That
/// constraint is deliberate: a topic vocabulary grows without bound, while a
/// destination vocabulary stays small enough for a small model to classify
/// reliably.
///
/// Assigned by the enrichment stage, correctable by the user. Nothing consumes
/// it yet; export is a later phase.
enum CaptureCategory {
  /// Durable knowledge or reference material.
  note,

  /// Actionable by a human.
  task,

  /// A prompt or spec meant for an AI agent to execute.
  agentTask,

  /// A product or business idea, not yet actionable.
  idea,

  /// Attendees plus decisions.
  meetingNote,

  /// A paper, link or topic to chase later.
  researchLead,

  /// Unclassified — the model looked and could not place it. Also the landing
  /// point for a name this build does not know.
  capture;

  /// Same degrade-don't-throw rule as `CaptureType.fromName`: JSON from a newer
  /// build (or a model that invented a label) restores as [capture] instead of
  /// taking the whole row down with it.
  static CaptureCategory fromName(String? name) =>
      CaptureCategory.values.asNameMap()[name] ?? CaptureCategory.capture;

  /// Polish, for the card chip and the edit sheet dropdown.
  String get label => switch (this) {
        CaptureCategory.note => 'NOTATKA',
        CaptureCategory.task => 'ZADANIE',
        CaptureCategory.agentTask => 'ZADANIE AI',
        CaptureCategory.idea => 'POMYSŁ',
        CaptureCategory.meetingNote => 'SPOTKANIE',
        CaptureCategory.researchLead => 'RESEARCH',
        CaptureCategory.capture => 'ZRZUT',
      };
}
```

- [ ] **Step 4: Run the test again**

Run: `flutter test test/enrichment_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/features/recordings/domain/capture_category.dart test/enrichment_test.dart
git commit -m "feat: CaptureCategory enum with legacy-safe fromName (#21)"
```

---

### Task 2: `Recording` gains category, summary and tags

**Files:**
- Modify: `lib/features/recordings/domain/recording.dart`
- Test: `test/recording_test.dart`

**Interfaces:**
- Consumes: `CaptureCategory` from Task 1
- Produces: `Recording.category` (`CaptureCategory?`), `Recording.summary` (`String?`), `Recording.tags` (`List<String>`), and `copyWith({CaptureCategory? category, bool clearCategory, String? summary, bool clearSummary, List<String>? tags})`

- [ ] **Step 1: Write the failing tests**

Append to the existing `main()` in `test/recording_test.dart`:

```dart
  test('category, summary and tags round-trip through JSON', () {
    final Recording item = Recording(
      id: 'id-1',
      filePath: '/tmp/id-1.m4a',
      createdAt: DateTime.parse('2026-07-30T10:00:00.000'),
      durationMs: 4200,
      status: RecordingStatus.completed,
      category: CaptureCategory.meetingNote,
      summary: 'Ustalenia ze spotkania.',
      tags: <String>['klient', 'oferta'],
    );

    final Recording restored = Recording.fromJson(item.toJson());

    expect(restored.category, CaptureCategory.meetingNote);
    expect(restored.summary, 'Ustalenia ze spotkania.');
    expect(restored.tags, <String>['klient', 'oferta']);
  });

  test('legacy JSON has no category, summary or tags', () {
    final Recording restored = Recording.fromJson(<String, dynamic>{
      'id': 'legacy',
      'filePath': '/tmp/legacy.m4a',
      'createdAt': '2026-01-01T00:00:00.000',
      'durationMs': 1000,
      'status': 'completed',
    });

    // Null, not `capture`: "never enriched" and "the model could not classify
    // it" are different states and the UI renders them differently.
    expect(restored.category, isNull);
    expect(restored.summary, isNull);
    expect(restored.tags, isEmpty);
  });

  test('an unknown category name degrades to capture', () {
    final Recording restored = Recording.fromJson(<String, dynamic>{
      'id': 'future',
      'filePath': '/tmp/future.m4a',
      'createdAt': '2026-01-01T00:00:00.000',
      'durationMs': 1000,
      'status': 'completed',
      'category': 'journal',
    });

    expect(restored.category, CaptureCategory.capture);
  });

  test('tags survive a non-list or mixed-type JSON value', () {
    final Recording broken = Recording.fromJson(<String, dynamic>{
      'id': 'broken',
      'filePath': '/tmp/broken.m4a',
      'createdAt': '2026-01-01T00:00:00.000',
      'durationMs': 1000,
      'status': 'completed',
      'tags': <dynamic>['ok', 7, null],
    });

    expect(broken.tags, <String>['ok']);
  });

  test('copyWith clears category and summary explicitly', () {
    final Recording item = Recording(
      id: 'id-2',
      filePath: '/tmp/id-2.m4a',
      createdAt: DateTime.parse('2026-07-30T10:00:00.000'),
      durationMs: 0,
      status: RecordingStatus.completed,
      category: CaptureCategory.task,
      summary: 'coś',
    );

    final Recording cleared =
        item.copyWith(clearCategory: true, clearSummary: true);

    expect(cleared.category, isNull);
    expect(cleared.summary, isNull);
  });
```

Add the import at the top of the file:

```dart
import 'package:voice_notes_phase1/features/recordings/domain/capture_category.dart';
```

- [ ] **Step 2: Run and watch it fail**

Run: `flutter test test/recording_test.dart`
Expected: FAIL — no named parameter `category`.

- [ ] **Step 3: Add the fields**

In `lib/features/recordings/domain/recording.dart`, add the import:

```dart
import 'capture_category.dart';
```

Add three constructor parameters after `this.title,`:

```dart
    this.category,
    this.summary,
    this.tags = const <String>[],
```

Add the fields after `title`:

```dart
  /// What the item *is*, assigned by the enrichment stage and correctable by
  /// the user.
  ///
  /// **Null and [CaptureCategory.capture] are different states.** Null means
  /// enrichment never ran — no profile configured, or the call failed.
  /// `capture` means it ran and could not place the item. Collapsing them would
  /// make an unconfigured install indistinguishable from a failing model.
  final CaptureCategory? category;

  /// One-line gist from the enrichment stage. Null until enriched.
  final String? summary;

  /// Up to five lowercase tags from the enrichment stage. Empty until enriched
  /// and on every legacy row.
  final List<String> tags;
```

Extend `copyWith`:

```dart
  Recording copyWith({
    RecordingStatus? status,
    String? transcript,
    String? title,
    bool clearTitle = false,
    CaptureCategory? category,
    bool clearCategory = false,
    String? summary,
    bool clearSummary = false,
    List<String>? tags,
    String? error,
    bool clearError = false,
    bool? isProcessedByUser,
    DateTime? processedAt,
    bool clearProcessedAt = false,
  }) {
    return Recording(
      id: id,
      filePath: filePath,
      createdAt: createdAt,
      durationMs: durationMs,
      sizeBytes: sizeBytes,
      type: type,
      sourceMimeType: sourceMimeType,
      status: status ?? this.status,
      transcript: transcript ?? this.transcript,
      title: clearTitle ? null : (title ?? this.title),
      category: clearCategory ? null : (category ?? this.category),
      summary: clearSummary ? null : (summary ?? this.summary),
      tags: tags ?? this.tags,
      error: clearError ? null : (error ?? this.error),
      isProcessedByUser: isProcessedByUser ?? this.isProcessedByUser,
      processedAt: clearProcessedAt ? null : (processedAt ?? this.processedAt),
    );
  }
```

Extend `toJson` after `'title': title,`:

```dart
        'category': category?.name,
        'summary': summary,
        'tags': tags,
```

Extend `fromJson` after `title: json['title'] as String?,`:

```dart
      // Absent on every row written before enrichment existed. `null` is
      // preserved as "never enriched"; only a *present* unknown name degrades
      // to `capture`.
      category: json['category'] == null
          ? null
          : CaptureCategory.fromName(json['category'] as String?),
      summary: json['summary'] as String?,
      // Type-filtered rather than cast: a hand-edited settings file holding a
      // non-list or a list with a stray number here would otherwise throw out
      // of the whole load, taking every other recording with it.
      tags: json['tags'] is List<dynamic>
          ? (json['tags'] as List<dynamic>).whereType<String>().toList()
          : const <String>[],
```

- [ ] **Step 4: Run the tests**

Run: `flutter test test/recording_test.dart && flutter analyze`
Expected: PASS, no analyzer issues.

- [ ] **Step 5: Commit**

```bash
git add lib/features/recordings/domain/recording.dart test/recording_test.dart
git commit -m "feat: persist category, summary and tags on Recording (#21)"
```

---

### Task 3: Enrichment domain — result, service interface, prompt

**Files:**
- Create: `lib/features/enrichment/domain/enrichment_result.dart`
- Create: `lib/features/enrichment/domain/enrichment_service.dart`
- Create: `lib/features/enrichment/domain/enrichment_prompt.dart`
- Test: `test/enrichment_test.dart` (append)

**Interfaces:**
- Consumes: `CaptureCategory` (Task 1)
- Produces:
  - `class EnrichmentResult {String? title; CaptureCategory category; String? summary; List<String> tags}` with `const EnrichmentResult({this.title, this.category = CaptureCategory.capture, this.summary, this.tags = const <String>[]})`
  - `abstract interface class EnrichmentService {Future<EnrichmentResult> enrich(String text);}`
  - `class DisabledEnrichmentService implements EnrichmentService` (const)
  - `class EnrichmentNotConfiguredException implements Exception`
  - `String buildEnrichmentSystemPrompt()`
  - `String truncateForEnrichment(String text)`

- [ ] **Step 1: Write the failing tests**

Append to `test/enrichment_test.dart`:

```dart
  group('enrichment prompt', () {
    test('lists every category, so the prompt cannot desync from the enum', () {
      final String prompt = buildEnrichmentSystemPrompt();
      for (final CaptureCategory value in CaptureCategory.values) {
        expect(prompt, contains(value.name));
      }
    });

    test('short text is passed through untouched', () {
      expect(truncateForEnrichment('krótka notatka'), 'krótka notatka');
    });

    test('long text keeps its head and its tail', () {
      final String long = '${'a' * 20000}KONIEC';
      final String cut = truncateForEnrichment(long);

      expect(cut.length, lessThan(long.length));
      expect(cut.startsWith('aaa'), isTrue);
      // The closing words of a recording usually carry the conclusion, so the
      // tail has to survive.
      expect(cut.endsWith('KONIEC'), isTrue);
      expect(cut, contains('[...]'));
    });
  });

  group('DisabledEnrichmentService', () {
    test('throws the not-configured exception', () {
      expect(
        () => const DisabledEnrichmentService().enrich('cokolwiek'),
        throwsA(isA<EnrichmentNotConfiguredException>()),
      );
    });
  });
```

Add the imports:

```dart
import 'package:voice_notes_phase1/features/enrichment/domain/enrichment_prompt.dart';
import 'package:voice_notes_phase1/features/enrichment/domain/enrichment_service.dart';
```

- [ ] **Step 2: Run and watch it fail**

Run: `flutter test test/enrichment_test.dart`
Expected: FAIL — those files do not exist.

- [ ] **Step 3: Write the three files**

```dart
// lib/features/enrichment/domain/enrichment_result.dart
import '../../recordings/domain/capture_category.dart';

/// What the enrichment model returned, after validation.
///
/// Every field is optional-ish on purpose: a model that returns a usable
/// category but a blank title should still produce a usable result. The caller
/// treats the whole stage as best-effort, so a partial result beats an
/// exception.
class EnrichmentResult {
  const EnrichmentResult({
    this.title,
    this.category = CaptureCategory.capture,
    this.summary,
    this.tags = const <String>[],
  });

  /// Null when the model returned nothing usable. The caller then leaves the
  /// item's existing title alone.
  final String? title;

  /// Never null — an unknown or missing label lands on
  /// [CaptureCategory.capture] rather than making the whole call a failure.
  final CaptureCategory category;

  final String? summary;

  /// Lowercase, deduped, at most five.
  final List<String> tags;
}
```

```dart
// lib/features/enrichment/domain/enrichment_service.dart
import 'enrichment_result.dart';

/// Turns processor-output text into a title, a category, a summary and tags.
///
/// Same shape as `TranscriptionService`: an interface, a disabled default that
/// throws, and one HTTP implementation. The default is what an unconfigured
/// install gets, and because the caller treats enrichment as best-effort, that
/// install simply ends up with un-enriched items rather than errors.
abstract interface class EnrichmentService {
  Future<EnrichmentResult> enrich(String text);
}

class DisabledEnrichmentService implements EnrichmentService {
  const DisabledEnrichmentService();

  @override
  Future<EnrichmentResult> enrich(String text) async {
    throw const EnrichmentNotConfiguredException();
  }
}

class EnrichmentNotConfiguredException implements Exception {
  const EnrichmentNotConfiguredException();

  @override
  String toString() => 'Enrichment endpoint is not configured.';
}
```

```dart
// lib/features/enrichment/domain/enrichment_prompt.dart
import '../../recordings/domain/capture_category.dart';

/// Head and tail kept when the text is longer than this. A 90-minute transcript
/// would otherwise cost more to enrich than it cost to transcribe.
const int _headChars = 8000;
const int _tailChars = 4000;

/// The system prompt, **generated from [CaptureCategory]** rather than written
/// out by hand.
///
/// A hand-written list desyncs from the enum the first time a category is added,
/// and the failure is silent: the model simply never emits the new label. The
/// `switch` below is exhaustive, so adding a value to the enum breaks the build
/// here until its description is written.
String buildEnrichmentSystemPrompt() {
  final StringBuffer buffer = StringBuffer()
    ..writeln(
      'You classify captured notes, transcripts and OCR text for a personal '
      'capture inbox. Reply with a single JSON object and nothing else.',
    )
    ..writeln()
    ..writeln('Fields:')
    ..writeln('- "title": max 60 characters, no trailing period.')
    ..writeln('- "category": exactly one of the values listed below.')
    ..writeln('- "summary": one sentence, max 200 characters.')
    ..writeln('- "tags": 3 to 5 short lowercase tags, no "#".')
    ..writeln()
    ..writeln(
      'Write "title" and "summary" in the same language as the input text.',
    )
    ..writeln()
    ..writeln('Categories (each is a routing destination, not a topic):');

  for (final CaptureCategory category in CaptureCategory.values) {
    buffer.writeln('- "${category.name}": ${_describe(category)}');
  }

  buffer
    ..writeln()
    ..writeln(
      'If none of them clearly fits, use "capture". Do not invent a category.',
    );
  return buffer.toString();
}

String _describe(CaptureCategory category) => switch (category) {
      CaptureCategory.note =>
        'durable knowledge or reference material worth keeping',
      CaptureCategory.task => 'something a person has to do',
      CaptureCategory.agentTask =>
        'an instruction or spec meant for an AI agent to execute',
      CaptureCategory.idea =>
        'a product or business idea that is not yet actionable',
      CaptureCategory.meetingNote =>
        'notes from a meeting or call, with people and decisions',
      CaptureCategory.researchLead =>
        'a paper, link, tool or topic to look into later',
      CaptureCategory.capture => 'anything that fits none of the above',
    };

/// Head + tail, so the closing words of a recording survive — they usually
/// carry the conclusion, and a head-only cut would drop it.
String truncateForEnrichment(String text) {
  if (text.length <= _headChars + _tailChars) return text;
  final String head = text.substring(0, _headChars);
  final String tail = text.substring(text.length - _tailChars);
  return '$head\n[...]\n$tail';
}
```

- [ ] **Step 4: Run the tests**

Run: `flutter test test/enrichment_test.dart && flutter analyze`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/features/enrichment test/enrichment_test.dart
git commit -m "feat: enrichment domain — result, service seam, enum-derived prompt (#21)"
```

---

### Task 4: `HttpChatEnrichmentService`

**Files:**
- Create: `lib/features/enrichment/data/http_chat_enrichment_service.dart`
- Test: `test/enrichment_test.dart` (append)

**Interfaces:**
- Consumes: `EnrichmentResult`, `EnrichmentService`, `buildEnrichmentSystemPrompt`, `truncateForEnrichment` (Task 3)
- Produces: `HttpChatEnrichmentService({required Uri endpoint, String? bearerToken, String? model, http.Client? client})`

- [ ] **Step 1: Write the failing tests**

Append to `test/enrichment_test.dart` (add `import 'package:http/http.dart' as http;`, `import 'package:http/testing.dart';` and the service import):

```dart
  group('HttpChatEnrichmentService', () {
    HttpChatEnrichmentService serviceReturning(
      String body, {
      int status = 200,
      void Function(http.Request request)? onRequest,
    }) {
      return HttpChatEnrichmentService(
        endpoint: Uri.parse('https://api.example.com/v1/chat/completions'),
        bearerToken: 'sk-test',
        model: 'gpt-4o-mini',
        client: MockClient((http.Request request) async {
          onRequest?.call(request);
          return http.Response(
            body,
            status,
            headers: <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }),
      );
    }

    String chatBody(String content) => jsonEncode(<String, dynamic>{
          'choices': <dynamic>[
            <String, dynamic>{
              'message': <String, dynamic>{'content': content},
            },
          ],
        });

    test('sends model, token and JSON response format', () async {
      late Map<String, dynamic> sent;
      late Map<String, String> headers;

      final HttpChatEnrichmentService service = serviceReturning(
        chatBody('{"title":"T","category":"note","summary":"S","tags":["a"]}'),
        onRequest: (http.Request request) {
          sent = jsonDecode(request.body) as Map<String, dynamic>;
          headers = request.headers;
        },
      );

      await service.enrich('treść notatki');

      expect(sent['model'], 'gpt-4o-mini');
      expect(
        (sent['response_format'] as Map<String, dynamic>)['type'],
        'json_object',
      );
      expect(headers['Authorization'], 'Bearer sk-test');
      final List<dynamic> messages = sent['messages'] as List<dynamic>;
      expect(messages.length, 2);
      expect((messages.first as Map<String, dynamic>)['role'], 'system');
      expect((messages.last as Map<String, dynamic>)['content'],
          contains('treść notatki'));
    });

    test('parses a clean response', () async {
      final EnrichmentResult result = await serviceReturning(chatBody(
        '{"title":"Spotkanie z klientem","category":"meetingNote",'
        '"summary":"Ustalenia.","tags":["Klient","OFERTA"]}',
      )).enrich('...');

      expect(result.title, 'Spotkanie z klientem');
      expect(result.category, CaptureCategory.meetingNote);
      expect(result.summary, 'Ustalenia.');
      expect(result.tags, <String>['klient', 'oferta']);
    });

    test('strips a markdown code fence around the JSON', () async {
      final EnrichmentResult result = await serviceReturning(chatBody(
        '```json\n{"title":"T","category":"task"}\n```',
      )).enrich('...');

      expect(result.title, 'T');
      expect(result.category, CaptureCategory.task);
    });

    test('an unknown category degrades to capture', () async {
      final EnrichmentResult result = await serviceReturning(
        chatBody('{"title":"T","category":"journal"}'),
      ).enrich('...');

      expect(result.category, CaptureCategory.capture);
    });

    test('a blank title becomes null and tags are capped at five', () async {
      final EnrichmentResult result = await serviceReturning(chatBody(
        '{"title":"   ","category":"note",'
        '"tags":["a","b","c","d","e","f","a"]}',
      )).enrich('...');

      expect(result.title, isNull);
      expect(result.tags, <String>['a', 'b', 'c', 'd', 'e']);
    });

    test('a non-JSON content body throws', () async {
      expect(
        () => serviceReturning(chatBody('nie wiem')).enrich('...'),
        throwsA(isA<FormatException>()),
      );
    });

    test('a non-2xx response throws', () async {
      expect(
        () => serviceReturning('{"error":"nope"}', status: 401).enrich('...'),
        throwsA(isA<HttpException>()),
      );
    });

    test('long input is truncated before it is sent', () async {
      late Map<String, dynamic> sent;
      final HttpChatEnrichmentService service = serviceReturning(
        chatBody('{"title":"T","category":"note"}'),
        onRequest: (http.Request request) =>
            sent = jsonDecode(request.body) as Map<String, dynamic>,
      );

      await service.enrich('x' * 30000);

      final String content = (sent['messages'] as List<dynamic>).last
          as Map<String, dynamic> is Map<String, dynamic>
          ? ((sent['messages'] as List<dynamic>).last
              as Map<String, dynamic>)['content'] as String
          : '';
      expect(content.length, lessThan(30000));
      expect(content, contains('[...]'));
    });
  });
```

Also add `import 'dart:convert';` and `import 'dart:io';` at the top of the test file.

- [ ] **Step 2: Run and watch it fail**

Run: `flutter test test/enrichment_test.dart`
Expected: FAIL — `HttpChatEnrichmentService` is undefined.

- [ ] **Step 3: Write the service**

```dart
// lib/features/enrichment/data/http_chat_enrichment_service.dart
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../recordings/domain/capture_category.dart';
import '../domain/enrichment_prompt.dart';
import '../domain/enrichment_result.dart';
import '../domain/enrichment_service.dart';

/// OpenAI-compatible `/v1/chat/completions` client.
///
/// Deliberately the same shape as `HttpWhisperTranscriptionService`: one POST,
/// an optional bearer token, a configurable model, and a defensive parse. Works
/// against OpenAI, Groq and a local Ollama without a code change, because all
/// three speak this body.
class HttpChatEnrichmentService implements EnrichmentService {
  HttpChatEnrichmentService({
    required this.endpoint,
    this.bearerToken,
    this.model,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final Uri endpoint;
  final String? bearerToken;

  /// Required by OpenAI and Groq, ignored by servers that don't read it.
  final String? model;
  final http.Client _client;

  /// More than five would be noise on a card, and the prompt already asks for
  /// three to five.
  static const int _maxTags = 5;

  @override
  Future<EnrichmentResult> enrich(String text) async {
    final Map<String, dynamic> payload = <String, dynamic>{
      if (model != null && model!.isNotEmpty) 'model': model,
      'response_format': <String, String>{'type': 'json_object'},
      'messages': <Map<String, String>>[
        <String, String>{
          'role': 'system',
          'content': buildEnrichmentSystemPrompt(),
        },
        <String, String>{
          'role': 'user',
          'content': truncateForEnrichment(text),
        },
      ],
    };

    final http.Response response = await _client.post(
      endpoint,
      headers: <String, String>{
        'content-type': 'application/json; charset=utf-8',
        if (bearerToken != null && bearerToken!.isNotEmpty)
          'Authorization': 'Bearer $bearerToken',
      },
      body: jsonEncode(payload),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'Enrichment failed (${response.statusCode}): ${response.body}',
      );
    }

    return parseResponse(utf8.decode(response.bodyBytes));
  }

  /// Exposed for tests, and kept separate from the transport so the parsing
  /// rules can be read in one piece.
  ///
  /// The degrade/throw split is deliberate: a body that *is* a JSON object
  /// degrades field by field, because a usable category with a blank title is
  /// still worth storing. A body that is not JSON at all throws, because there
  /// is nothing to degrade to and the caller should log it.
  static EnrichmentResult parseResponse(String body) {
    final dynamic envelope = jsonDecode(body);
    if (envelope is! Map<String, dynamic>) {
      throw const FormatException('Response is not a JSON object.');
    }

    final dynamic choices = envelope['choices'];
    final dynamic first = choices is List<dynamic> && choices.isNotEmpty
        ? choices.first
        : null;
    final dynamic message =
        first is Map<String, dynamic> ? first['message'] : null;
    final dynamic content =
        message is Map<String, dynamic> ? message['content'] : null;
    if (content is! String) {
      throw const FormatException('Response contains no message content.');
    }

    final dynamic decoded = jsonDecode(_stripFence(content));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Message content is not a JSON object.');
    }

    return EnrichmentResult(
      title: _cleanText(decoded['title']),
      category: CaptureCategory.fromName(
        decoded['category'] is String ? decoded['category'] as String : null,
      ),
      summary: _cleanText(decoded['summary']),
      tags: _cleanTags(decoded['tags']),
    );
  }

  /// Models with a JSON mode still wrap their output in a fence often enough
  /// that not handling it would be the most common failure in the log.
  static String _stripFence(String raw) {
    final String trimmed = raw.trim();
    if (!trimmed.startsWith('```')) return trimmed;
    final int firstBreak = trimmed.indexOf('\n');
    if (firstBreak < 0) return trimmed;
    final String withoutOpen = trimmed.substring(firstBreak + 1);
    final int closing = withoutOpen.lastIndexOf('```');
    return (closing < 0 ? withoutOpen : withoutOpen.substring(0, closing))
        .trim();
  }

  static String? _cleanText(dynamic value) {
    if (value is! String) return null;
    final String trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static List<String> _cleanTags(dynamic value) {
    if (value is! List<dynamic>) return const <String>[];
    final List<String> tags = <String>[];
    for (final dynamic item in value) {
      if (item is! String) continue;
      final String tag = item.trim().toLowerCase().replaceAll('#', '');
      if (tag.isEmpty || tags.contains(tag)) continue;
      tags.add(tag);
      if (tags.length == _maxTags) break;
    }
    return tags;
  }
}
```

- [ ] **Step 4: Run the tests**

Run: `flutter test test/enrichment_test.dart && flutter analyze`
Expected: PASS. If the "long input is truncated" test reads awkwardly, simplify its content extraction to:

```dart
      final String content = ((sent['messages'] as List<dynamic>).last
          as Map<String, dynamic>)['content'] as String;
```

- [ ] **Step 5: Commit**

```bash
git add lib/features/enrichment/data test/enrichment_test.dart
git commit -m "feat: OpenAI-compatible chat enrichment client (#21)"
```

---

### Task 5: Controller wiring — best-effort enrichment after completion

**Files:**
- Modify: `lib/features/recordings/presentation/recordings_controller.dart`
- Test: `test/enrichment_controller_test.dart` (create)

**Interfaces:**
- Consumes: `EnrichmentService`, `EnrichmentResult` (Tasks 3–4), `Recording.copyWith` (Task 2)
- Produces: `RecordingsController({... EnrichmentService enrichmentService = const DisabledEnrichmentService()})`, `set enrichmentService(EnrichmentService)`, `Future<void> setCategory(String id, CaptureCategory? category)`

- [ ] **Step 1: Write the failing tests**

Model the harness on `test/processing_queue_test.dart` — read it first and reuse its fake repository/processor setup rather than inventing a second one.

```dart
// test/enrichment_controller_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_notes_phase1/features/enrichment/domain/enrichment_result.dart';
import 'package:voice_notes_phase1/features/enrichment/domain/enrichment_service.dart';
import 'package:voice_notes_phase1/features/recordings/domain/capture_category.dart';
import 'package:voice_notes_phase1/features/recordings/domain/recording.dart';

class _FakeEnrichment implements EnrichmentService {
  _FakeEnrichment(this.result);
  final EnrichmentResult result;
  int calls = 0;
  String? lastText;

  @override
  Future<EnrichmentResult> enrich(String text) async {
    calls++;
    lastText = text;
    return result;
  }
}

class _ThrowingEnrichment implements EnrichmentService {
  int calls = 0;

  @override
  Future<EnrichmentResult> enrich(String text) async {
    calls++;
    throw StateError('boom');
  }
}

void main() {
  // Every test: build a controller with a fake repository and a fake processor
  // that returns a fixed string, add a text note, then
  // `await controller.waitForProcessing()`.

  test('fills title, category, summary and tags on a completed item', () async {
    // enrichment returns title 'Notatka', category note, summary 'Gist.',
    // tags ['a','b']
    // expect the item's status to still be completed
    // expect title/category/summary/tags to match
  });

  test('never overwrites a user-set title', () async {
    // set a title via controller.setTitle(id, 'Moje') before retrying
    // retryTranscription(id) → waitForProcessing()
    // expect title still 'Moje', but category updated
  });

  test('a throwing enrichment service leaves the item completed', () async {
    // expect status completed, category null, error null
    // expect the fake's `calls` to be 1 — it was attempted
  });

  test('the disabled service is a silent no-op', () async {
    // default constructor arg; expect category null and status completed
  });

  test('a blank processor output is not sent for enrichment', () async {
    // processor returns '   '
    // expect fake.calls == 0
  });

  test('setCategory overwrites the model verdict and persists', () async {
    // controller.setCategory(id, CaptureCategory.task)
    // expect recordings.single.category == task
    // reload from the repository and expect the same
  });

  test('setCategory(null) clears the category', () async {
    // expect category null after the call
  });
}
```

Write these out fully against the harness in `test/processing_queue_test.dart` — the bodies above are the assertions to implement, not comments to leave in the file.

- [ ] **Step 2: Run and watch it fail**

Run: `flutter test test/enrichment_controller_test.dart`
Expected: FAIL — no `enrichmentService` parameter.

- [ ] **Step 3: Wire the controller**

Add the imports:

```dart
import '../../enrichment/domain/enrichment_result.dart';
import '../../enrichment/domain/enrichment_service.dart';
import '../domain/capture_category.dart';
```

Add the constructor parameter next to `transcriptionService`:

```dart
    EnrichmentService enrichmentService = const DisabledEnrichmentService(),
```

with the initializer `_enrichmentService = enrichmentService,` and the field beside the other swappable services:

```dart
  EnrichmentService _enrichmentService;
```

Add the setter next to `set transcriptionService`:

```dart
  /// Applied to the next enrichment attempt. A job already running keeps the
  /// service it started with.
  set enrichmentService(EnrichmentService value) {
    if (identical(_enrichmentService, value)) return;
    _enrichmentService = value;
  }
```

In `_processOne`, after the existing `await _copyToClipboard(...)` line inside the success branch, add:

```dart
        // Deliberately last, and deliberately after the `completed` write: the
        // item is already durable, so a model outage, a malformed response or a
        // kill in this window costs a title, never a capture.
        await _enrich(id, transcript);
```

Add the method next to `_copyToClipboard`:

```dart
  /// Ask the enrichment model to name and classify freshly derived text.
  ///
  /// Best-effort by construction: it runs after the item is `completed` on
  /// disk, it never touches `status`, and it swallows every error into the log
  /// — the same contract as [_copyToClipboard]. An unconfigured install throws
  /// `EnrichmentNotConfiguredException` here on every item, which is why the
  /// not-configured case is logged at `warn` and not at `error`.
  Future<void> _enrich(String id, String text) async {
    if (text.trim().isEmpty) return;
    try {
      final EnrichmentResult result = await _enrichmentService.enrich(text);
      if (_disposed) return;
      await _update(
        id,
        (Recording item) => item.copyWith(
          // Only when empty. A user-set title is permanent: a retry must not
          // silently destroy a name someone typed.
          title: (item.title ?? '').trim().isEmpty ? result.title : null,
          category: result.category,
          summary: result.summary,
          tags: result.tags,
        ),
      );
      _logSink.log(
        'Enriched · ${result.category.name}',
        recordingId: id,
      );
    } on EnrichmentNotConfiguredException {
      // Expected on every item until a profile is configured; not an error.
      _logSink.log(
        'Enrichment skipped — no profile configured.',
        level: LogLevel.warn,
        recordingId: id,
      );
    } catch (exception) {
      _logSink.log(
        'Enrichment failed: $exception',
        level: LogLevel.warn,
        recordingId: id,
      );
    }
  }
```

Add the user-correction entry point next to `setTitle`:

```dart
  /// Overwrite the model's verdict. Null clears it back to "unclassified" — a
  /// wrong category is worse than none, because an export will read this field.
  Future<void> setCategory(String id, CaptureCategory? category) async {
    await _update(
      id,
      (Recording item) => item.copyWith(
        category: category,
        clearCategory: category == null,
      ),
    );
    _logSink.log(
      category == null ? 'Category cleared.' : 'Category set · ${category.name}',
      recordingId: id,
    );
  }
```

- [ ] **Step 4: Run the tests**

Run: `flutter test && flutter analyze`
Expected: PASS across the whole suite — `processing_queue_test.dart` must still pass unchanged, which is the check that enrichment did not alter the state machine.

- [ ] **Step 5: Commit**

```bash
git add lib/features/recordings/presentation/recordings_controller.dart test/enrichment_controller_test.dart
git commit -m "feat: run enrichment as a best-effort stage after completion (#21)"
```

---

### Task 6: Profile kind and the enrichment service in settings

**Files:**
- Modify: `lib/features/settings/domain/provider_profile.dart`
- Modify: `lib/features/settings/domain/app_settings.dart`
- Modify: `lib/features/settings/presentation/settings_controller.dart`
- Test: `test/settings_test.dart`

**Interfaces:**
- Consumes: `HttpChatEnrichmentService` (Task 4)
- Produces:
  - `enum ProfileKind {transcription, enrichment}` with `static ProfileKind fromName(String?)` → `transcription`
  - `ProviderProfile.kind`, `ProviderProfile.toEnrichmentService()`
  - `AppSettings.activeEnrichmentProfileId`, `AppSettings.activeEnrichmentProfile`, `copyWith({String? activeEnrichmentProfileId, bool clearActiveEnrichmentProfileId})`
  - `SettingsController.enrichmentService`, `SettingsController.profilesOfKind(ProfileKind)`, `addProfile({..., ProfileKind kind = ProfileKind.transcription})`, `setActiveEnrichmentProfile(String?)`

- [ ] **Step 1: Write the failing tests**

Append to `test/settings_test.dart`:

```dart
  test('a legacy profile row defaults to the transcription kind', () {
    final ProviderProfile restored = ProviderProfile.fromJson(<String, dynamic>{
      'id': 'p1',
      'name': 'Whisper',
      'endpoint': 'https://api.openai.com/v1/audio/transcriptions',
    });

    expect(restored.kind, ProfileKind.transcription);
  });

  test('kind round-trips and an unknown kind degrades to transcription', () {
    const ProviderProfile profile = ProviderProfile(
      id: 'p2',
      name: 'GPT',
      endpoint: 'https://api.openai.com/v1/chat/completions',
      kind: ProfileKind.enrichment,
    );

    expect(ProviderProfile.fromJson(profile.toJson()).kind,
        ProfileKind.enrichment);
    expect(ProfileKind.fromName('embedding'), ProfileKind.transcription);
  });

  test('toEnrichmentService degrades on a blank or schemeless endpoint', () {
    const ProviderProfile blank =
        ProviderProfile(id: 'x', name: 'x', endpoint: '  ');
    const ProviderProfile schemeless =
        ProviderProfile(id: 'y', name: 'y', endpoint: 'api.example.com/v1');

    expect(blank.toEnrichmentService(), isA<DisabledEnrichmentService>());
    expect(schemeless.toEnrichmentService(), isA<DisabledEnrichmentService>());
  });

  test('activeEnrichmentProfile is null for a dangling id', () {
    const AppSettings settings = AppSettings(
      profiles: <ProviderProfile>[],
      activeEnrichmentProfileId: 'gone',
    );

    expect(settings.activeEnrichmentProfile, isNull);
  });

  test('the two active ids are independent', () async {
    // With one profile of each kind added through the controller:
    // expect settings.activeProfileId to point at the transcription profile
    // expect settings.activeEnrichmentProfileId to point at the enrichment one
    // expect controller.transcriptionService to be a HttpWhisperTranscriptionService
    // expect controller.enrichmentService to be a HttpChatEnrichmentService
  });

  test('deleting the active enrichment profile falls back, never dangles',
      () async {
    // add two enrichment profiles, delete the active one
    // expect activeEnrichmentProfileId to be the surviving profile's id
    // delete the last one
    // expect activeEnrichmentProfileId to be null and enrichmentService
    // to be a DisabledEnrichmentService
  });

  test('enrichmentService is cached until the connection details change',
      () async {
    // expect identical(controller.enrichmentService, controller.enrichmentService)
    // after updateProfile with a new model, expect a different instance
  });
```

Write the last three out fully against the existing `_FakeSettingsRepository` in that file.

- [ ] **Step 2: Run and watch it fail**

Run: `flutter test test/settings_test.dart`
Expected: FAIL — `ProfileKind` is undefined.

- [ ] **Step 3: Implement**

In `provider_profile.dart`, add the import and the enum above `ProviderProfile`:

```dart
import '../../enrichment/data/http_chat_enrichment_service.dart';
import '../../enrichment/domain/enrichment_service.dart';

/// What a profile is *for*. One list holds both kinds because everything else
/// about them — name, endpoint, model, token, editor UI — is identical; only
/// the request body differs, and that lives in the two `to…Service()` methods.
enum ProfileKind {
  transcription,
  enrichment;

  /// Legacy rows have no `kind`, and every profile written before enrichment
  /// existed was a transcription profile.
  static ProfileKind fromName(String? name) =>
      ProfileKind.values.asNameMap()[name] ?? ProfileKind.transcription;

  /// Polish, for the section headers in the Models tab.
  String get label => switch (this) {
        ProfileKind.transcription => 'TRANSKRYPCJA',
        ProfileKind.enrichment => 'OPIS I KATEGORIA',
      };
}
```

Add `this.kind = ProfileKind.transcription,` to the constructor, the field, `kind` to `copyWith` (as `ProfileKind? kind`), `'kind': kind.name` to `toJson`, and `kind: ProfileKind.fromName(json['kind'] as String?)` to `fromJson`. Then add:

```dart
  /// Build the enrichment service for this profile. Same blank-or-schemeless
  /// guard as [toService]: a half-filled profile degrades to the disabled
  /// service instead of throwing mid-pipeline.
  EnrichmentService toEnrichmentService() {
    final Uri? uri = hasEndpoint ? Uri.tryParse(endpoint.trim()) : null;
    if (uri == null || !uri.hasScheme) {
      return const DisabledEnrichmentService();
    }
    return HttpChatEnrichmentService(
      endpoint: uri,
      bearerToken: _blankToNull(bearerToken),
      model: _blankToNull(model),
    );
  }
```

Add to `ProviderPreset`: a `kind` field (default `ProfileKind.transcription`), and three enrichment presets in `all`:

```dart
    ProviderPreset(
      name: 'OpenAI GPT-4o mini',
      endpoint: 'https://api.openai.com/v1/chat/completions',
      model: 'gpt-4o-mini',
      kind: ProfileKind.enrichment,
    ),
    ProviderPreset(
      name: 'Groq Llama 3.3',
      endpoint: 'https://api.groq.com/openai/v1/chat/completions',
      model: 'llama-3.3-70b-versatile',
      kind: ProfileKind.enrichment,
    ),
    ProviderPreset(
      name: 'Lokalny Ollama',
      endpoint: 'http://localhost:11434/v1/chat/completions',
      kind: ProfileKind.enrichment,
    ),
```

In `app_settings.dart`: add `this.activeEnrichmentProfileId,` to the constructor and the field, add `activeEnrichmentProfileId` + `clearActiveEnrichmentProfileId` to `copyWith` (mirroring the existing pair exactly), add the key to `toJson`, read it type-checked in `fromJson` (`json['activeEnrichmentProfileId'] is String ? … : null`), and add:

```dart
  /// Null when nothing is selected or the stored id no longer exists. Callers
  /// fall back to the disabled enrichment service.
  ProviderProfile? get activeEnrichmentProfile {
    if (activeEnrichmentProfileId == null) return null;
    for (final ProviderProfile profile in profiles) {
      if (profile.id == activeEnrichmentProfileId) return profile;
    }
    return null;
  }
```

In `settings_controller.dart`:

```dart
  EnrichmentService? _enrichment;
  String? _enrichmentSignature;

  /// Profiles of one kind, for the two Models-tab sections.
  List<ProviderProfile> profilesOfKind(ProfileKind kind) => _settings.profiles
      .where((ProviderProfile item) => item.kind == kind)
      .toList();

  ProviderProfile? get activeEnrichmentProfile =>
      _settings.activeEnrichmentProfile;

  /// Same caching rule as [transcriptionService]: the same instance — and so
  /// the same `http.Client` — until the active profile's connection details
  /// actually change.
  EnrichmentService get enrichmentService {
    final ProviderProfile? active = _settings.activeEnrichmentProfile;
    final String signature = active == null
        ? 'disabled'
        : <String?>[active.id, active.endpoint, active.model, active.bearerToken]
            .join('|');

    if (_enrichment == null || _enrichmentSignature != signature) {
      _enrichment =
          active?.toEnrichmentService() ?? const DisabledEnrichmentService();
      _enrichmentSignature = signature;
    }
    return _enrichment!;
  }

  Future<void> setActiveEnrichmentProfile(String? id) async {
    await _persist(
      _settings.copyWith(
        activeEnrichmentProfileId: id,
        clearActiveEnrichmentProfileId: id == null,
      ),
    );
  }
```

Give `addProfile` a `ProfileKind kind = ProfileKind.transcription` parameter, pass it to the constructed profile, and make the "newly added profile becomes active" line kind-aware:

```dart
    await _persist(
      _settings.copyWith(
        profiles: <ProviderProfile>[..._settings.profiles, profile],
        // A newly added profile becomes the active one *of its own kind* —
        // adding an enrichment profile must not silently repoint transcription.
        activeProfileId: kind == ProfileKind.transcription
            ? profile.id
            : _settings.activeProfileId,
        activeEnrichmentProfileId: kind == ProfileKind.enrichment
            ? profile.id
            : _settings.activeEnrichmentProfileId,
      ),
    );
```

Rewrite `deleteProfile` so it resolves **both** active ids against the survivors, each falling back to the first remaining profile *of that kind*:

```dart
  Future<void> deleteProfile(String id) async {
    final List<ProviderProfile> remaining = _settings.profiles
        .where((ProviderProfile item) => item.id != id)
        .toList();

    String? resolve(String? current, ProfileKind kind) {
      final bool survives =
          remaining.any((ProviderProfile item) => item.id == current);
      if (survives) return current;
      for (final ProviderProfile item in remaining) {
        if (item.kind == kind) return item.id;
      }
      return null;
    }

    final String? nextActive =
        resolve(_settings.activeProfileId, ProfileKind.transcription);
    final String? nextEnrichment = resolve(
      _settings.activeEnrichmentProfileId,
      ProfileKind.enrichment,
    );

    await _persist(
      _settings.copyWith(
        profiles: remaining,
        activeProfileId: nextActive,
        clearActiveProfileId: nextActive == null,
        activeEnrichmentProfileId: nextEnrichment,
        clearActiveEnrichmentProfileId: nextEnrichment == null,
      ),
    );
  }
```

- [ ] **Step 4: Run the tests**

Run: `flutter test && flutter analyze`
Expected: PASS. The existing `settings_test.dart` cases must pass untouched — that is the backward-compatibility check.

- [ ] **Step 5: Commit**

```bash
git add lib/features/settings test/settings_test.dart
git commit -m "feat: profile kinds and an active enrichment profile (#21)"
```

---

### Task 7: Models tab — two sections

**Files:**
- Modify: `lib/features/settings/presentation/models_tab.dart`
- Test: `test/widget/models_tab_test.dart`

**Interfaces:**
- Consumes: `profilesOfKind`, `setActiveEnrichmentProfile`, `addProfile(kind:)` (Task 6)
- Produces: no new public API

- [ ] **Step 1: Write the failing widget test**

Read `test/widget/models_tab_test.dart` first and follow its existing pump helper. Add:

```dart
  testWidgets('renders a section per profile kind', (WidgetTester tester) async {
    // seed the controller with one transcription and one enrichment profile
    await tester.pumpWidget(/* existing harness */);

    expect(find.text('TRANSKRYPCJA'), findsOneWidget);
    expect(find.text('OPIS I KATEGORIA'), findsOneWidget);
  });

  testWidgets('activating an enrichment profile leaves transcription alone',
      (WidgetTester tester) async {
    // tap the second enrichment profile's card
    // expect controller.settings.activeEnrichmentProfileId to change
    // expect controller.settings.activeProfileId to be unchanged
  });

  testWidgets('the empty enrichment section explains what it is for',
      (WidgetTester tester) async {
    // with no enrichment profiles, expect an EmptyPanel in that section
  });
```

- [ ] **Step 2: Run and watch it fail**

Run: `flutter test test/widget/models_tab_test.dart`
Expected: FAIL — no `OPIS I KATEGORIA` header.

- [ ] **Step 3: Implement**

Extract the existing profile-list body into a private `_ProfileSection` widget parameterised by `ProfileKind`, then render it twice. Keep everything else — `_ActiveProfileCard`, `_ProfileCard`, `_ProfileEditorSheet` — shared; the only kind-dependent pieces are:

- the section header (`kind.label`) and item count,
- which controller setter a tap calls (`setActiveProfile` vs `setActiveEnrichmentProfile`),
- which profile the "active" card reads (`activeProfile` vs `activeEnrichmentProfile`),
- the empty-state copy: `'Brak profili transkrypcji.'` / `'Brak profili opisu. Bez nich elementy nie dostaną tytułu ani kategorii.'`,
- the presets offered in the editor sheet (`ProviderPreset.all.where((p) => p.kind == kind)`).

`_ProfileDraft` and `_ProfileEditorSheet` take a `ProfileKind kind` and pass it to `addProfile`. The language field is transcription-only — hide it for enrichment profiles, since the chat request does not send one.

- [ ] **Step 4: Run the tests**

Run: `flutter test && flutter analyze`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/features/settings/presentation/models_tab.dart test/widget/models_tab_test.dart
git commit -m "feat: split the Models tab into transcription and enrichment sections (#21)"
```

---

### Task 8: Card chip, summary line, and an editable category

**Files:**
- Modify: `lib/features/recordings/presentation/recording_card.dart`
- Modify: `lib/features/recordings/presentation/edit_sheet.dart`
- Modify: `lib/features/recordings/presentation/queue_tab.dart:167-177`
- Test: `test/widget/queue_tab_test.dart`

**Interfaces:**
- Consumes: `Recording.category/summary/tags` (Task 2), `RecordingsController.setCategory` (Task 5)
- Produces: `EditResult({required String title, required String transcript, required CaptureCategory? category})`

- [ ] **Step 1: Write the failing widget tests**

```dart
  testWidgets('a card shows its category and summary', (WidgetTester tester) async {
    // seed one completed recording with category: CaptureCategory.task,
    // summary: 'Zadzwonić do klienta.'
    expect(find.text('ZADANIE'), findsOneWidget);
    expect(find.text('Zadzwonić do klienta.'), findsOneWidget);
  });

  testWidgets('an un-enriched card shows no category chip',
      (WidgetTester tester) async {
    // seed one completed recording with category: null
    // expect no chip and no summary line — an unconfigured install must look
    // exactly like it does today
  });

  testWidgets('the edit sheet returns a corrected category',
      (WidgetTester tester) async {
    // open the sheet, pick 'NOTATKA' from the dropdown, save
    // expect controller.recordings.single.category == CaptureCategory.note
  });
```

- [ ] **Step 2: Run and watch it fail**

Run: `flutter test test/widget/queue_tab_test.dart`
Expected: FAIL.

- [ ] **Step 3: Implement**

In `recording_card.dart`, add `import '../domain/capture_category.dart';`, then render the category beside the status pill by replacing the trailing `StatusPill(...)` with:

```dart
                Wrap(
                  spacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    // Reuses StatusPill rather than adding a widget: the two
                    // read as one row of state, and the colour is what tells
                    // them apart.
                    if (recording.category != null)
                      StatusPill(
                        label: recording.category!.label,
                        color: Console.mutedSoft,
                        pulse: false,
                      ),
                    StatusPill(
                      label: visual.label,
                      color: visual.color,
                      pulse: visual.pulse,
                    ),
                  ],
                ),
```

Add the summary directly under the header `Row`, before the `transcribing` progress bar:

```dart
            if ((recording.summary ?? '').trim().isNotEmpty) ...<Widget>[
              const SizedBox(height: 9),
              Text(
                recording.summary!.trim(),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: ConsoleText.cardMeta.copyWith(color: Console.textSoft),
              ),
            ],
```

In `edit_sheet.dart`: add `category` to `EditResult`, hold `CaptureCategory? _category = widget.recording.category` in the state, and insert between the title and text fields:

```dart
          const SizedBox(height: 12),
          DropdownButtonFormField<CaptureCategory?>(
            initialValue: _category,
            dropdownColor: Console.surfaceRaised,
            decoration: const InputDecoration(labelText: 'Kategoria'),
            style: const TextStyle(color: Console.text, fontSize: 14),
            items: <DropdownMenuItem<CaptureCategory?>>[
              const DropdownMenuItem<CaptureCategory?>(
                value: null,
                child: Text('—'),
              ),
              for (final CaptureCategory value in CaptureCategory.values)
                DropdownMenuItem<CaptureCategory?>(
                  value: value,
                  child: Text(value.label),
                ),
            ],
            onChanged: (CaptureCategory? value) =>
                setState(() => _category = value),
          ),
```

If the installed Flutter version rejects `initialValue` on `DropdownButtonFormField`, use `value:` instead — check which the SDK in this checkout accepts and keep the analyzer clean.

Below the text field, render the read-only enrichment output when present:

```dart
          if (widget.recording.tags.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                for (final String tag in widget.recording.tags)
                  ConsoleChip(
                    label: tag,
                    selected: false,
                    // Read-only: tags come from the model and this sheet has no
                    // tag editor. A no-op tap keeps the visual language of the
                    // app without implying an affordance that does not exist.
                    onSelected: () {},
                  ),
              ],
            ),
          ],
```

In `queue_tab.dart`, extend the save path:

```dart
    await widget.controller.setTitle(recording.id, result.title);
    await widget.controller.editTranscript(recording.id, result.transcript);
    await widget.controller.setCategory(recording.id, result.category);
```

- [ ] **Step 4: Run the tests**

Run: `flutter test && flutter analyze`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/features/recordings/presentation test/widget/queue_tab_test.dart
git commit -m "feat: show the category and summary, and let the user correct them (#21)"
```

---

### Task 9: Shell wiring and documentation

**Files:**
- Modify: `lib/features/recordings/presentation/recordings_page.dart:164-171`
- Modify: `CLAUDE.md`
- Test: whole suite

**Interfaces:**
- Consumes: `SettingsController.enrichmentService` (Task 6), `RecordingsController.enrichmentService` (Task 5)
- Produces: nothing

- [ ] **Step 1: Push the service on every settings change**

In `_applySettings`, next to the existing line:

```dart
    controller.transcriptionService = settings.transcriptionService;
    controller.enrichmentService = settings.enrichmentService;
```

- [ ] **Step 2: Verify by hand**

Run: `flutter analyze`
Expected: clean. Confirm by reading that no other call site constructs `RecordingsController` without the default — the parameter has a `const DisabledEnrichmentService()` default, so tests and the shell both compile.

- [ ] **Step 3: Document the feature in CLAUDE.md**

Add an `**Enrichment**` paragraph after the `**Processing**` one, covering: the `features/enrichment/` layout; that it runs as a best-effort stage *after* the `completed` write and never changes status; that the title is filled only when empty; that the system prompt is generated from `CaptureCategory` so it cannot desync; the head+tail truncation; and that `ProviderProfile.kind` splits one profile list into two Models-tab sections with two independent active ids.

Extend the `**Two independent state axes**` paragraph to mention `category` (nullable = never enriched, `capture` = classified as unclassifiable), `summary` and `tags`.

Extend the **Settings** paragraph with `activeEnrichmentProfileId`.

- [ ] **Step 4: Run the full gate**

Run: `flutter analyze && flutter test`
Expected: PASS, zero analyzer issues.

- [ ] **Step 5: Commit**

```bash
git add lib/features/recordings/presentation/recordings_page.dart CLAUDE.md
git commit -m "feat: wire enrichment into the shell; document the stage (#21)"
```

---

## Self-Review

**Spec coverage:** category vocabulary → Task 1; `Recording` fields → Task 2; service seam, disabled default, enum-derived prompt, truncation → Task 3; HTTP client and parsing rules → Task 4; pipeline placement, title rule, best-effort failure, all capture types → Task 5; `ProfileKind`, second active id, presets, cached service → Task 6; two Models-tab sections → Task 7; card chip, summary, editable category, read-only tags → Task 8; shell wiring and docs → Task 9. No spec section is unclaimed.

**Type consistency:** `EnrichmentService.enrich(String) → Future<EnrichmentResult>` is used identically in Tasks 3–6. `CaptureCategory.fromName` and `ProfileKind.fromName` share the `asNameMap()` shape. `Recording.copyWith` gains exactly the flags Task 5 and Task 8 call.

**Known risk:** Task 8 depends on which `DropdownButtonFormField` parameter name this Flutter SDK accepts (`initialValue` vs `value`); the step says to check rather than assume.
