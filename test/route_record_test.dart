import 'dart:convert';

import 'package:augustyniak_capture/features/recordings/domain/route_record.dart';
import 'package:augustyniak_capture/features/projects/domain/native_agent_types.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('an assistant route round-trips through JSON', () {
    final RouteRecord record = RouteRecord(
      at: DateTime.utc(2026, 10, 6, 12),
      kind: RouteKind.assistant,
      target: 'ChatGPT · web',
    );

    final RouteRecord? back = RouteRecord.fromJson(record.toJson());

    expect(back, isNotNull);
    expect(back!.kind, RouteKind.assistant);
    expect(back.target, 'ChatGPT · web');
    expect(record.toJson()['kind'], 'assistant');
  });

  test('legacy kinds still read back unchanged', () {
    for (final String name in <String>['file', 'agent', 'command']) {
      final RouteRecord? back = RouteRecord.fromJson(<String, dynamic>{
        'at': '2026-10-06T12:00:00.000Z',
        'kind': name,
        'target': 'x',
      });
      expect(back?.kind.name, name);
    }
  });

  test('an unknown kind is still dropped rather than guessed', () {
    expect(RouteKind.fromName('teleport'), isNull);
    expect(
      RouteRecord.fromJson(<String, dynamic>{
        'at': '2026-10-06T12:00:00.000Z',
        'kind': 'teleport',
        'target': 'x',
      }),
      isNull,
    );
  });

  test('an agent route keeps the session it opened', () {
    final RouteRecord record = RouteRecord(
      at: DateTime.utc(2026, 10, 21, 9),
      kind: RouteKind.agent,
      target: 'Claude Code · augustyniak-capture-1234abcd-claude',
      session: 'augustyniak-capture-1234abcd-claude',
    );

    final RouteRecord? back = RouteRecord.fromJson(record.toJson());

    expect(back!.session, 'augustyniak-capture-1234abcd-claude');
    expect(record.toJson()['session'], 'augustyniak-capture-1234abcd-claude');
    // Carried across an outcome update, like every other field.
    expect(back.withOutcome(null).session, record.session);
    // Only a name the launcher could have produced is kept: a hand-edited,
    // synced or archived row cannot plant an option or a path into
    // `zellij attach <name>`. The route itself survives.
    for (final Object? bad in <Object?>[
      '  ',
      '--help',
      '-x',
      'a b',
      '../x',
      'x' * 65,
      42,
    ]) {
      final RouteRecord? back = RouteRecord.fromJson(<String, dynamic>{
        ...record.toJson(),
        'session': bad,
      });
      expect(back, isNotNull, reason: '$bad');
      expect(back!.session, isNull, reason: '$bad');
    }
    expect(isSafeSessionName('capture-abc123-codex'), isTrue);
    expect(isSafeSessionName('my.project_1-claude'), isTrue);
  });

  test('a legacy row serialises byte for byte as it was read', () {
    final Map<String, dynamic> legacy = <String, dynamic>{
      'at': '2026-10-06T12:00:00.000Z',
      'kind': 'agent',
      'target': 'claude',
    };

    final RouteRecord? record = RouteRecord.fromJson(legacy);

    expect(jsonEncode(record!.toJson()), jsonEncode(legacy));
  });

  test('a native job is typed and never becomes a legacy session', () {
    const NativeAgentJobHandle job = NativeAgentJobHandle(
      id: '019a019e-9590-45f5-b4d7-60a391ada56f',
      backend: NativeAgentBackend.codex,
    );
    final RouteRecord record = RouteRecord(
      at: DateTime.utc(2026, 10, 23),
      kind: RouteKind.agent,
      target: 'Codex · background job',
      agentJob: job,
    );

    final RouteRecord back = RouteRecord.fromJson(record.toJson())!;

    expect(back.agentJob?.id, job.id);
    expect(back.agentJob?.backend, NativeAgentBackend.codex);
    expect(back.session, isNull);
    expect(back.withOutcome(null).agentJob?.id, job.id);
  });

  Map<String, dynamic> withDecision(Object? decision) => <String, dynamic>{
    'at': '2026-10-06T12:00:00.000Z',
    'kind': 'command',
    'target': 'host',
    'decision': ?decision,
  };

  test('legacy JSON: a row without decision serialises byte for byte', () {
    final Map<String, dynamic> legacy = withDecision(null);
    final RouteRecord? record = RouteRecord.fromJson(legacy);
    expect(record, isNotNull);
    expect(jsonEncode(record!.toJson()), jsonEncode(legacy));
    expect(record.toJson().containsKey('decision'), isFalse);
  });

  test('decision round-trips', () {
    final Map<String, dynamic> json = withDecision(<String, dynamic>{
      'ruleId': 'R10',
      'reason': 'bound to Command',
    });
    final RouteRecord? record = RouteRecord.fromJson(json);
    expect(record!.toJson()['decision'], <String, dynamic>{
      'ruleId': 'R10',
      'reason': 'bound to Command',
    });
    expect(jsonEncode(record.toJson()), jsonEncode(json));
  });

  test('withOutcome keeps decision', () {
    final RouteRecord record = RouteRecord.fromJson(
      withDecision(<String, dynamic>{'ruleId': 'R10', 'reason': 'why'}),
    )!;
    expect(record.withOutcome(null).toJson()['decision'], <String, dynamic>{
      'ruleId': 'R10',
      'reason': 'why',
    });
  });

  test('decision without ruleId is dropped', () {
    for (final Object bad in <Object>[
      <String, dynamic>{'reason': 'orphan'},
      <String, dynamic>{'ruleId': '  ', 'reason': 'blank'},
      <String, dynamic>{'ruleId': 7},
      'R10',
    ]) {
      final RouteRecord? record = RouteRecord.fromJson(withDecision(bad));
      expect(record, isNotNull, reason: '$bad');
      expect(record!.toJson().containsKey('decision'), isFalse, reason: '$bad');
    }
  });

  // --- #474: external kind and agent decision fields -----------------------

  const String did0 = '123e4567-e89b-42d3-a456-426614174000';

  test('an external route round-trips and is not dropped', () {
    // AC-5
    final RouteRecord? record = RouteRecord.fromJson(<String, dynamic>{
      'at': '2026-11-27T12:00:00.000Z',
      'kind': 'external',
      'target': 'codex',
    });
    expect(record, isNotNull);
    expect(record!.toJson()['kind'], 'external');
    expect(RouteKind.fromName('external')?.name, 'external');
  });

  test('decision carries decidedBy, did and decisionId through JSON', () {
    // AC-5
    final Map<String, dynamic> decision = <String, dynamic>{
      'ruleId': 'agent',
      'reason': 'F2: already filed',
      'decidedBy': 'agent:codex',
      'did': 'opened PR #12',
      'decisionId': did0,
    };
    final RouteRecord record = RouteRecord.fromJson(withDecision(decision))!;
    expect(record.toJson()['decision'], decision);
    // Carried across an outcome update like every other field.
    expect(record.withOutcome(null).toJson()['decision'], decision);
  });

  test('legacy JSON: a decision without the new keys re-serialises byte for '
      'byte and gains none', () {
    // AC-7
    final Map<String, dynamic> legacy = withDecision(<String, dynamic>{
      'ruleId': 'R10',
      'reason': 'bound to Command',
    });
    final RouteRecord record = RouteRecord.fromJson(legacy)!;
    expect(jsonEncode(record.toJson()), jsonEncode(legacy));
    final Map<String, dynamic> out =
        record.toJson()['decision'] as Map<String, dynamic>;
    expect(out.keys, <String>['ruleId', 'reason']);
  });

  test('blank or mistyped decidedBy/did/decisionId degrade to absent', () {
    // AC-7
    for (final Object? bad in <Object?>['  ', '', 7, true]) {
      final RouteRecord? record = RouteRecord.fromJson(
        withDecision(<String, dynamic>{
          'ruleId': 'R10',
          'reason': 'why',
          'decidedBy': bad,
          'did': bad,
          'decisionId': bad,
        }),
      );
      expect(record, isNotNull, reason: '$bad');
      expect(record!.toJson()['decision'], <String, dynamic>{
        'ruleId': 'R10',
        'reason': 'why',
      }, reason: '$bad');
    }
  });

  test('an unknown kind is still dropped after external was added', () {
    // AC-7
    expect(RouteKind.fromName('externall'), isNull);
    expect(
      RouteRecord.fromJson(<String, dynamic>{
        'at': '2026-11-27T12:00:00.000Z',
        'kind': 'externall',
        'target': 'x',
      }),
      isNull,
    );
  });
}
