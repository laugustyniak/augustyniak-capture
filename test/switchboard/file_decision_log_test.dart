import 'dart:convert';
import 'dart:io';

import 'package:augustyniak_capture/features/recordings/domain/capture_category.dart';
import 'package:augustyniak_capture/features/recordings/domain/suggested_route.dart';
import 'package:augustyniak_capture/features/switchboard/data/file_decision_log.dart';
import 'package:augustyniak_capture/features/switchboard/domain/capture_facts.dart';
import 'package:augustyniak_capture/features/switchboard/domain/context_facts.dart';
import 'package:augustyniak_capture/features/switchboard/domain/decision.dart';
import 'package:augustyniak_capture/features/switchboard/domain/decision_log.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

Decision _decision(
  String ruleId,
  SuggestedRouteKind kind, {
  ContextFacts context = ContextFacts.none,
}) => Decision(
  ruleId: ruleId,
  kind: kind,
  reason: 'because $ruleId',
  context: context,
  facts: CaptureFacts(
    category: CaptureCategory.agentTask,
    projectId: 'proj',
    availableRouteKinds: const <SuggestedRouteKind>[SuggestedRouteKind.command],
    modelRoute: SuggestedRouteKind.file,
  ),
);

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('decision_log'));
  tearDown(() => root.deleteSync(recursive: true));

  test('creates the directory and appends to decisions.jsonl', () async {
    final Directory nested = Directory(p.join(root.path, 'a', 'b'));
    final FileDecisionLog log = FileDecisionLog(directory: () async => nested);

    await log.append(
      at: DateTime.utc(2026, 11, 23, 9),
      captureId: 'rec-1',
      decision: _decision('R10', SuggestedRouteKind.command),
      applied: true,
    );

    final File file = File(p.join(nested.path, 'decisions.jsonl'));
    expect(file.existsSync(), isTrue);
    expect(file.readAsLinesSync(), hasLength(1));
  });

  test('a row carries every field, and rows accumulate', () async {
    final FileDecisionLog log = FileDecisionLog(directory: () async => root);
    await log.append(
      at: DateTime.utc(2026, 11, 23, 9),
      captureId: 'rec-1',
      decision: _decision('R10', SuggestedRouteKind.command),
      applied: true,
    );
    await log.append(
      at: DateTime.utc(2026, 11, 23, 10),
      captureId: 'rec-2',
      decision: _decision('R90', SuggestedRouteKind.none),
      applied: false,
      skipReason: 'dismissed',
    );

    final List<Map<String, dynamic>> rows = FileDecisionLog.parse(
      File(p.join(root.path, 'decisions.jsonl')).readAsStringSync(),
    );
    expect(rows, hasLength(2));
    expect(rows[0]['captureId'], 'rec-1');
    expect(rows[0]['ruleId'], 'R10');
    expect(rows[0]['kind'], 'command');
    expect(rows[0]['reason'], 'because R10');
    expect(rows[0]['applied'], isTrue);
    expect(rows[0]['at'], DateTime.utc(2026, 11, 23, 9).toIso8601String());
    expect(rows[0]['facts'], containsPair('category', 'agentTask'));
    expect(rows[0]['facts'], containsPair('projectId', 'proj'));
    expect(
      rows[0]['facts'],
      containsPair('availableRouteKinds', <String>['command']),
    );
    expect(rows[0]['facts'], containsPair('modelRoute', 'file'));
    expect(rows[1]['ruleId'], 'R90');
    expect(rows[1]['kind'], 'none');
    expect(rows[1]['applied'], isFalse);
    expect(rows[1]['skipReason'], 'dismissed');
  });

  // AC-5
  test('a v0 row has no context key', () async {
    final FileDecisionLog log = FileDecisionLog(directory: () async => root);
    await log.append(
      at: DateTime.utc(2026, 11, 23, 9),
      captureId: 'rec-1',
      decision: _decision('R10', SuggestedRouteKind.command),
      applied: true,
    );
    final List<Map<String, dynamic>> rows = FileDecisionLog.parse(
      File(p.join(root.path, 'decisions.jsonl')).readAsStringSync(),
    );
    expect(rows.single.containsKey('context'), isFalse);
  });

  // AC-5
  test('a row logs the priority count, tier and status, never the items',
      () async {
    final FileDecisionLog log = FileDecisionLog(directory: () async => root);
    await log.append(
      at: DateTime.utc(2026, 11, 23, 9),
      captureId: 'rec-1',
      decision: _decision(
        'R10',
        SuggestedRouteKind.command,
        context: const ContextFacts(
          priorities: <String>['Ship the alpha', 'Renew the domain'],
          tier: 1,
          status: 'active',
        ),
      ),
      applied: true,
    );
    final String raw = File(
      p.join(root.path, 'decisions.jsonl'),
    ).readAsStringSync();
    final List<Map<String, dynamic>> rows = FileDecisionLog.parse(raw);
    expect(rows.single['context'], <String, dynamic>{
      'priorityCount': 2,
      'tier': 1,
      'status': 'active',
    });
    // The note is private: no item text may reach decisions.jsonl, which is
    // a backup payload member.
    expect(raw, isNot(contains('Ship the alpha')));
    expect(raw, isNot(contains('Renew the domain')));
  });

  test('parse skips a torn line and keeps every other row', () {
    final String good = jsonEncode(<String, dynamic>{
      'at': '2026-11-23T09:00:00.000Z',
      'captureId': 'x',
      'ruleId': 'R10',
      'kind': 'command',
    });
    final List<Map<String, dynamic>> rows = FileDecisionLog.parse(
      '$good\n{"at":"2026-11-23T09:\n\n$good\n',
    );
    expect(rows, hasLength(2));
  });

  test('NoopDecisionLog accepts a row and does nothing', () async {
    await const NoopDecisionLog().append(
      at: DateTime.utc(2026),
      captureId: 'x',
      decision: _decision('R10', SuggestedRouteKind.command),
      applied: true,
    );
  });
}
