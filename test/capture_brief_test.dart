import 'dart:io';

import 'package:augustyniak_capture/features/projects/domain/agent_session_launcher.dart';
import 'package:augustyniak_capture/features/projects/domain/project.dart';
import 'package:augustyniak_capture/features/recordings/data/project_agent_handoff.dart';
import 'package:augustyniak_capture/features/recordings/domain/agent_handoff.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_brief.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_category.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_router.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _FakeLauncher implements AgentSessionLauncher {
  @override
  Future<AgentSessionLaunchResult> launch(
    AgentSessionLaunchRequest request,
  ) async => const AgentSessionLaunchResult(
    sessionName: 'augustyniak-acme-p1-claude',
    attachedToExistingSession: false,
  );
}

RoutedCapture _capture({
  String title = 'Split the router before the index work lands',
  String body = 'We agreed to postpone the migration.',
  String? summary = 'Router split agreed; migration deferred.',
  CaptureCategory? category = CaptureCategory.agentTask,
  List<String> tags = const <String>['backend', 'migration'],
  CaptureType type = CaptureType.audioRecording,
}) => RoutedCapture(
  projectId: 'p1',
  title: title,
  body: body,
  summary: summary,
  category: category,
  tags: tags,
  type: type,
  capturedAt: DateTime.utc(2026, 8, 5, 14, 32, 11, 482),
);

/// The front-matter block, read the way a YAML reader reads one: a fence on the
/// very first line opens it, the next fence line closes it. Deliberately not
/// reusing anything from `lib/` — a test that parses with the writer's own code
/// cannot catch the writer emitting a shape nothing else can read.
({Map<String, String> fields, String body})? _parse(String brief) {
  final List<String> lines = brief.split('\n');
  if (lines.isEmpty || lines.first.trim() != '---') return null;
  final int close = lines.indexWhere(
    (String line) => line.trim() == '---',
    1,
  );
  if (close < 0) return null;

  final Map<String, String> fields = <String, String>{};
  for (final String line in lines.sublist(1, close)) {
    final int colon = line.indexOf(':');
    if (colon <= 0) continue;
    fields[line.substring(0, colon).trim()] = line.substring(colon + 1).trim();
  }
  return (fields: fields, body: lines.sublist(close + 1).join('\n'));
}

void main() {
  group('front matter', () {
    test('carries every key the format defines', () {
      final String brief = renderCaptureBrief(
        captureId: '3f2a1c4e-c81b',
        capture: _capture(),
        at: DateTime.utc(2026, 8, 5, 14, 40),
        includeHeader: true,
        resultPath: '.agent-tasks/3f2a1c4e-c81b-result.md',
        intent: 'only write tests',
      );

      final Map<String, String> fields = _parse(brief)!.fields;
      expect(fields['capture-id'], '3f2a1c4e-c81b');
      expect(fields['created'], '2026-08-05T14:32:11.482Z');
      expect(fields['source'], 'audioRecording');
      expect(fields['category'], 'agentTask');
      expect(fields['tags'], '["backend", "migration"]');
      expect(fields['intent'], '"only write tests"');
    });

    test('the body below it is the capture, heading first', () {
      final String body = _parse(
        renderCaptureBrief(
          captureId: 'cap-1',
          capture: _capture(),
          at: DateTime.utc(2026, 8, 5, 14, 40),
          includeHeader: true,
          resultPath: '.agent-tasks/cap-1-result.md',
        ),
      )!.body;

      expect(body, contains('# Split the router before the index work lands'));
      expect(body, contains('> Router split agreed; migration deferred.'));
      expect(body, contains('We agreed to postpone the migration.'));
      expect(body, contains('## Handoff 2026-08-05T14:40:00.000Z'));
    });

    test('a key with no answer is absent rather than blank', () {
      // `category: ` reads as the value null in YAML, which is a claim that the
      // capture was classified as nothing. A null category means enrichment
      // never ran, and the two must not collapse.
      final Map<String, String> fields = _parse(
        renderCaptureBrief(
          captureId: 'cap-1',
          capture: _capture(category: null, tags: const <String>[]),
          at: DateTime.utc(2026, 8, 5, 14, 40),
          includeHeader: true,
          resultPath: '.agent-tasks/cap-1-result.md',
        ),
      )!.fields;

      expect(fields.containsKey('category'), isFalse);
      expect(fields.containsKey('tags'), isFalse);
      expect(fields.containsKey('intent'), isFalse);
      expect(fields['capture-id'], 'cap-1');
    });

    test('a later section carries no front matter of its own', () {
      final String later = renderCaptureBrief(
        captureId: 'cap-1',
        capture: _capture(),
        at: DateTime.utc(2026, 8, 5, 15),
        includeHeader: false,
        resultPath: '.agent-tasks/cap-1-result.md',
      );

      expect(later.trimLeft(), startsWith('## Handoff'));
      expect(later, isNot(contains('capture-id:')));
    });
  });

  group('a transcript is text, not structure', () {
    test('a --- line inside the transcript does not close the front matter', () {
      const String transcript =
          'First the preamble.\n'
          '---\n'
          'capture-id: not-the-real-one\n'
          'source: forged\n'
          '---\n'
          'and then the actual conclusion.';

      final ({Map<String, String> fields, String body}) parsed = _parse(
        renderCaptureBrief(
          captureId: 'cap-real',
          capture: _capture(body: transcript),
          at: DateTime.utc(2026, 8, 5, 14, 40),
          includeHeader: true,
          resultPath: '.agent-tasks/cap-real-result.md',
        ),
      )!;

      // The exact key set, not merely the right values for the keys asked
      // about. Asserting values alone passes even when the block never closes
      // and the transcript's own `---` ends it — the real keys are all above
      // the leak, so every value still reads correctly while the block has
      // swallowed the heading and the output contract on its way down.
      expect(parsed.fields.keys.toSet(), <String>{
        'capture-id',
        'created',
        'source',
        'category',
        'tags',
      });
      expect(parsed.fields['capture-id'], 'cap-real');
      expect(parsed.fields['source'], 'audioRecording');

      // The block closes before the prose, and the forged keys are body text.
      expect(parsed.body.trimLeft(), startsWith('# '));
      expect(parsed.body, contains('capture-id: not-the-real-one'));
      expect(parsed.body, contains('and then the actual conclusion.'));
    });

    test('Polish diacritics survive the round trip', () {
      const String polish =
          'Zaczęliśmy od wdrożenia, potem poszło źle — ćwierć godziny na łączu.';
      final String brief = renderCaptureBrief(
        captureId: 'cap-1',
        capture: _capture(
          title: 'Notatka o wdrożeniu',
          body: polish,
          summary: 'Skrócone omówienie wdrożenia.',
          tags: const <String>['wdrożenie', 'łączność'],
        ),
        at: DateTime.utc(2026, 8, 5, 14, 40),
        includeHeader: true,
        resultPath: '.agent-tasks/cap-1-result.md',
      );

      final ({Map<String, String> fields, String body}) parsed = _parse(brief)!;
      expect(parsed.fields['tags'], '["wdrożenie", "łączność"]');
      expect(parsed.body, contains('# Notatka o wdrożeniu'));
      expect(parsed.body, contains(polish));
    });
  });

  group('the file the launcher writes', () {
    late Directory repo;

    setUp(() {
      repo = Directory.systemTemp.createTempSync('augustyniak_brief_');
    });

    tearDown(() => repo.deleteSync(recursive: true));

    Future<void> handoff(String captureId) => ProjectAgentHandoff(
      projectById: (String id) =>
          Project(id: 'p1', name: 'Acme', repoPath: repo.path),
      launcher: _FakeLauncher(),
    ).handoff(
      AgentHandoffRequest(
        captureId: captureId,
        capture: _capture(),
        agentId: 'claudeCode',
        instruction: 'Split the router.',
      ),
    );

    test('opens with the front matter and the output contract', () async {
      await handoff('cap-1');

      final String brief = File(
        p.join(repo.path, '.agent-tasks', 'cap-1.md'),
      ).readAsStringSync();
      expect(brief, startsWith('---\n'));
      expect(_parse(brief)!.fields['capture-id'], 'cap-1');
      expect(brief, contains('.agent-tasks/cap-1-result.md'));
    });

    test('a second handoff appends and leaves the agent\'s own work alone', () async {
      await handoff('cap-1');

      final File file = File(p.join(repo.path, '.agent-tasks', 'cap-1.md'));
      const String agentNotes = '\n## What I found\n\nThe router is fine.\n';
      file.writeAsStringSync(agentNotes, mode: FileMode.writeOnlyAppend);

      await handoff('cap-1');

      final String brief = file.readAsStringSync();
      expect(
        agentNotes.allMatches(brief),
        hasLength(1),
        reason: 'the second handoff overwrote what the agent had written',
      );
      expect('## Handoff '.allMatches(brief), hasLength(2));
      expect(
        '\n---\n'.allMatches(brief),
        hasLength(1),
        reason: 'a second front-matter block would sit in the middle of the file',
      );
    });
  });
}
