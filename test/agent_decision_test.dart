import 'dart:convert';

import 'package:augustyniak_capture/features/recordings/domain/agent_decision.dart';
import 'package:flutter_test/flutter_test.dart';

/// Types to be created by #474 in `agent_decision.dart` (pure Dart, only
/// `dart:convert` plus `core/security/record_id.dart`):
/// - `enum AgentDecisionAction { done, routeFile, routeCommand, skip }` with
///   `static AgentDecisionAction? fromName(Object?)` over the wire names
///   `done`, `route_file`, `route_command`, `skip` (null when unknown).
/// - `AgentDecision({decisionId, captureId, version, action, reason, did,
///   target, agent, submittedAt})`, `toJson()`, `static AgentDecision?
///   fromJson(Object?)` (null on any invalid field).
void main() {
  const String id = '123e4567-e89b-42d3-a456-426614174000';

  Map<String, dynamic> valid() => <String, dynamic>{
    'decisionId': id,
    'captureId': 'cap-1',
    'version': 'abc',
    'action': 'route_file',
    'reason': 'F2: belongs in the repo inbox',
    'did': 'wrote the note',
    'target': 'inbox.md',
    'agent': 'codex',
    'submittedAt': '2026-11-27T10:00:00.000Z',
  };

  test('round-trips through JSON', () {
    // AC-5
    final AgentDecision d = AgentDecision.fromJson(valid())!;
    expect(d.decisionId, id);
    expect(d.captureId, 'cap-1');
    expect(d.version, 'abc');
    expect(d.action, AgentDecisionAction.routeFile);
    expect(d.reason, 'F2: belongs in the repo inbox');
    expect(d.did, 'wrote the note');
    expect(d.target, 'inbox.md');
    expect(d.agent, 'codex');
    expect(d.submittedAt, DateTime.utc(2026, 11, 27, 10));
    expect(
      AgentDecision.fromJson(jsonDecode(jsonEncode(d.toJson()))),
      isNotNull,
    );
    expect(d.toJson()['action'], 'route_file');
    expect(d.toJson()['captureId'], 'cap-1');
  });

  test('did and target are optional and omitted when absent', () {
    // AC-5
    final Map<String, dynamic> json = valid()
      ..remove('did')
      ..remove('target');
    final AgentDecision d = AgentDecision.fromJson(json)!;
    expect(d.did, isNull);
    expect(d.target, isNull);
    expect(d.toJson().containsKey('did'), isFalse);
    expect(d.toJson().containsKey('target'), isFalse);
  });

  test('every wire action parses and an unknown one is null', () {
    // AC-5
    expect(AgentDecisionAction.fromName('done'), AgentDecisionAction.done);
    expect(
      AgentDecisionAction.fromName('route_file'),
      AgentDecisionAction.routeFile,
    );
    expect(
      AgentDecisionAction.fromName('route_command'),
      AgentDecisionAction.routeCommand,
    );
    expect(AgentDecisionAction.fromName('skip'), AgentDecisionAction.skip);
    expect(AgentDecisionAction.fromName('snooze_until'), isNull);
    expect(AgentDecisionAction.fromName(null), isNull);
  });

  test('anything invalid degrades to null rather than throwing', () {
    // AC-5
    final Map<String, Object?> bad = <String, Object?>{
      'bad action': <String, Object?>{'action': 'delete'},
      'numeric action': <String, Object?>{'action': 3},
      'path traversal id': <String, Object?>{'captureId': '../x'},
      'empty id': <String, Object?>{'captureId': ''},
      'slash id': <String, Object?>{'captureId': 'a/b'},
      'agent space': <String, Object?>{'agent': 'a b'},
      'agent slash': <String, Object?>{'agent': 'a/b'},
      'agent empty': <String, Object?>{'agent': ''},
      'agent too long': <String, Object?>{'agent': 'x' * 41},
      'reason too long': <String, Object?>{'reason': 'r' * 2001},
      'did too long': <String, Object?>{'did': 'd' * 2001},
      'missing version': <String, Object?>{'version': null},
      'blank version': <String, Object?>{'version': '  '},
      'missing reason': <String, Object?>{'reason': null},
      'missing decisionId': <String, Object?>{'decisionId': null},
      'missing agent': <String, Object?>{'agent': null},
    };
    bad.forEach((String why, Object? patch) {
      final Map<String, dynamic> json = valid();
      (patch as Map<String, Object?>).forEach((String k, Object? v) {
        if (v == null) {
          json.remove(k);
        } else {
          json[k] = v;
        }
      });
      expect(AgentDecision.fromJson(json), isNull, reason: why);
    });
    for (final Object? junk in <Object?>[null, 'x', 3, <Object?>[]]) {
      expect(AgentDecision.fromJson(junk), isNull, reason: '$junk');
    }
  });

  test('the length caps are inclusive at 2000', () {
    // AC-5
    final Map<String, dynamic> json = valid()
      ..['reason'] = 'r' * 2000
      ..['did'] = 'd' * 2000
      ..['agent'] = 'x' * 40;
    expect(AgentDecision.fromJson(json), isNotNull);
  });
}
