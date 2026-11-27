import 'dart:convert';
import 'dart:io';

import 'package:augustyniak_capture/features/mcp/data/decision_store.dart';
import 'package:augustyniak_capture/features/mcp/data/sqlite_capture_source.dart';
import 'package:augustyniak_capture/features/mcp/domain/capture_tools.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'mcp_call.dart';
import 'mcp_fixture.dart';

/// Types to be created by #474, assumed here:
/// `DecisionStore({required String directory, void Function(String)? log})`
/// with `Future<Set<String>> pendingCaptureIds()`, and a `decisions:` named
/// argument on `CaptureTools` (the `allowDecisions` flag stays at its default,
/// off, throughout this file: pending exclusion must work without it).
void main() {
  const String idA = '123e4567-e89b-42d3-a456-426614174000';
  const String idB = '223e4567-e89b-42d3-a456-426614174000';
  const String idC = '323e4567-e89b-42d3-a456-426614174000';
  late McpFixture fx;
  late Directory decisions;
  late List<String> logged;

  setUp(() {
    fx = McpFixture();
    decisions = Directory(p.join(fx.dir.path, 'decisions'));
    logged = <String>[];
  });
  tearDown(() => fx.dispose());

  String decisionJson(String decisionId, String captureId) =>
      jsonEncode(<String, dynamic>{
        'decisionId': decisionId,
        'captureId': captureId,
        'version': 'v',
        'action': 'done',
        'reason': 'F1',
        'agent': 'codex',
        'submittedAt': '2026-11-27T10:00:00.000Z',
      });

  File put(String relative, String content) {
    final File f = File(p.join(decisions.path, relative));
    f.parent.createSync(recursive: true);
    return f..writeAsStringSync(content);
  }

  DecisionStore store() =>
      DecisionStore(directory: decisions.path, log: logged.add);

  test('a missing directory is empty and is not created', () async {
    // AC-3
    expect(await store().pendingCaptureIds(), isEmpty);
    expect(decisions.existsSync(), isFalse);
  });

  test('pending ids come from decisions/*.json only', () async {
    // AC-3
    put('$idA.json', decisionJson(idA, 'cap-a'));
    put('$idB.json.tmp', decisionJson(idB, 'cap-tmp'));
    put('rejected/$idC.json', decisionJson(idC, 'cap-rejected'));
    put('rejected/$idC.reason.txt', 'stale version');
    put('notes.txt', 'cap-txt');
    expect(await store().pendingCaptureIds(), <String>{'cap-a'});
  });

  test('a malformed or oversize file hides nothing and is logged', () async {
    // AC-3
    put('$idA.json', decisionJson(idA, 'cap-a'));
    put('$idB.json', '{not json');
    put('$idC.json', decisionJson(idC, 'x' * 70000));
    expect(await store().pendingCaptureIds(), <String>{'cap-a'});
    expect(logged, isNotEmpty);
  });

  test('a symlinked decisions directory is refused and not read', () async {
    // AC-2
    final Directory outside = Directory.systemTemp.createTempSync('outside_');
    addTearDown(() => outside.deleteSync(recursive: true));
    File(
      p.join(outside.path, '$idA.json'),
    ).writeAsStringSync(decisionJson(idA, 'cap-outside'));
    Link(decisions.path).createSync(outside.path);
    expect(await store().pendingCaptureIds(), isEmpty);
  });

  group('next_open_captures with a store', () {
    CaptureTools tools() => CaptureTools(
      SqliteCaptureSource(
        dbPath: fx.dbPath,
        recordingsDir: fx.recordingsDir.path,
      ),
      decisions: store(),
    );

    Future<List<String>> openIds() async {
      final Map<String, dynamic> page =
          (await callBody(tools(), 'next_open_captures', <String, dynamic>{}))
              as Map<String, dynamic>;
      return <String>[
        for (final dynamic c in page['captures'] as List)
          (c as Map<String, dynamic>)['id'] as String,
      ];
    }

    setUp(() {
      fx.insert(rec('cap-a', at: DateTime.utc(2026, 1, 1)));
      fx.insert(rec('cap-b', at: DateTime.utc(2026, 1, 2)));
    });

    test('a capture with a pending decision is not returned', () async {
      // AC-3
      expect(await openIds(), <String>['cap-a', 'cap-b']);
      put('$idA.json', decisionJson(idA, 'cap-a'));
      expect(await openIds(), <String>['cap-b']);
    });

    test('the same decision in rejected/ returns the capture', () async {
      // AC-3
      put('rejected/$idA.json', decisionJson(idA, 'cap-a'));
      expect(await openIds(), <String>['cap-a', 'cap-b']);
    });

    test('a malformed file does not hide a capture', () async {
      // AC-3
      put('$idA.json', '{"captureId": ');
      expect(await openIds(), <String>['cap-a', 'cap-b']);
    });
  });
}
