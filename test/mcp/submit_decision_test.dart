import 'dart:convert';
import 'dart:io';

import 'package:augustyniak_capture/features/mcp/data/decision_store.dart';
import 'package:augustyniak_capture/features/mcp/data/sqlite_capture_source.dart';
import 'package:augustyniak_capture/features/mcp/domain/capture_source.dart';
import 'package:augustyniak_capture/features/mcp/domain/capture_tools.dart';
import 'package:augustyniak_capture/features/mcp/domain/mcp_server.dart';
import 'package:augustyniak_capture/features/projects/domain/project.dart';
import 'package:augustyniak_capture/features/recordings/domain/agent_decision.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'mcp_fixture.dart';

/// Types to be created by #474, assumed here: `DecisionStore({required String
/// directory, void Function(String)? log})`; `CaptureTools(source, decisions:
/// DecisionStore?, allowDecisions: bool = false)`; `AgentDecision.fromJson`.
///
/// The source throws on every read: `submit_decision` must not touch the
/// database at all (the app verifies the capture, the server does not).
class _NoReadSource implements CaptureSource {
  @override
  Future<List<Recording>> recordings() => throw StateError('db read');
  @override
  Future<List<({Recording recording, String payload})>>
  recordingsWithPayload() => throw StateError('db read');
  @override
  Future<List<Project>> projects() => throw StateError('db read');
}

void main() {
  late McpFixture fx;
  late Directory decisions;

  setUp(() {
    fx = McpFixture();
    fx.insert(rec('cap-1'));
    decisions = Directory(p.join(fx.dir.path, 'decisions'));
  });
  tearDown(() => fx.dispose());

  CaptureTools tools({required bool allow, CaptureSource? source}) =>
      CaptureTools(
        source ?? _NoReadSource(),
        decisions: DecisionStore(directory: decisions.path),
        allowDecisions: allow,
      );

  Map<String, dynamic> args({
    String id = 'cap-1',
    Map<String, dynamic>? more,
  }) => <String, dynamic>{
    'id': id,
    'version': 'abc123',
    'action': 'done',
    'reason': 'F2: already handled',
    'did': 'opened PR #12',
    'agent': 'codex',
    ...?more,
  };

  List<File> files() => decisions.existsSync()
      ? decisions.listSync().whereType<File>().toList()
      : <File>[];

  Future<List<Map<String, dynamic>>> rpc(
    CaptureTools t,
    List<Map<String, dynamic>> msgs,
  ) async {
    final List<String> out = <String>[];
    await McpServer(
      t,
    ).serve(Stream<String>.fromIterable(msgs.map(jsonEncode)), out.add);
    return out
        .map((String l) => jsonDecode(l) as Map<String, dynamic>)
        .toList();
  }

  Map<String, dynamic> listReq() => <String, dynamic>{
    'jsonrpc': '2.0',
    'id': 1,
    'method': 'tools/list',
  };

  Map<String, dynamic> callReq(Map<String, dynamic> a) => <String, dynamic>{
    'jsonrpc': '2.0',
    'id': 2,
    'method': 'tools/call',
    'params': <String, dynamic>{'name': 'submit_decision', 'arguments': a},
  };

  List<dynamic> toolList(Map<String, dynamic> r) =>
      (r['result'] as Map)['tools'] as List<dynamic>;

  test('without --allow-decisions the tool is not listed', () async {
    // AC-2
    final Map<String, dynamic> r = (await rpc(
      tools(allow: false),
      <Map<String, dynamic>>[listReq()],
    )).single;
    final Iterable<dynamic> names = toolList(
      r,
    ).map((dynamic t) => (t as Map)['name']);
    expect(names, contains('next_open_captures'));
    expect(names, isNot(contains('submit_decision')));
  });

  test(
    'without --allow-decisions a call is refused and writes nothing',
    () async {
      // AC-2
      final Map<String, dynamic> r = (await rpc(
        tools(allow: false),
        <Map<String, dynamic>>[callReq(args())],
      )).single;
      expect((r['error'] as Map)['code'], -32602);
      expect(decisions.existsSync(), isFalse);
      await expectLater(
        tools(allow: false).call('submit_decision', args()),
        throwsA(isA<InvalidParams>()),
      );
    },
  );

  test('with the flag the tool is listed with its schema', () async {
    // AC-2
    final Map<String, dynamic> r = (await rpc(
      tools(allow: true),
      <Map<String, dynamic>>[listReq()],
    )).single;
    final Map<String, dynamic> tool = toolList(r)
        .cast<Map<String, dynamic>>()
        .singleWhere(
          (Map<String, dynamic> t) => t['name'] == 'submit_decision',
        );
    final Map<String, dynamic> schema =
        tool['inputSchema'] as Map<String, dynamic>;
    expect(
      (schema['properties'] as Map).keys,
      containsAll(<String>[
        'id',
        'version',
        'action',
        'reason',
        'did',
        'target',
        'agent',
      ]),
    );
    expect(
      schema['required'],
      containsAll(<String>['id', 'version', 'action', 'reason', 'agent']),
    );
    expect(schema['required'], isNot(contains('did')));
    expect(schema['required'], isNot(contains('target')));
  });

  test('one call writes exactly one file that the app can read back', () async {
    // AC-2
    final Map<String, dynamic> result = await tools(
      allow: true,
    ).call('submit_decision', args(more: <String, dynamic>{'target': 'inbox'}));
    expect(result['isError'], isNull, reason: '$result');
    final List<File> written = files();
    expect(written, hasLength(1));
    expect(p.basename(written.single.path), endsWith('.json'));
    expect(
      decisions.listSync().whereType<File>().where(
        (File f) => f.path.endsWith('.tmp'),
      ),
      isEmpty,
    );

    final AgentDecision? d = AgentDecision.fromJson(
      jsonDecode(written.single.readAsStringSync()),
    );
    expect(d, isNotNull);
    expect(p.basenameWithoutExtension(written.single.path), d!.decisionId);
    expect(d.captureId, 'cap-1');
    expect(d.version, 'abc123');
    expect(d.action, AgentDecisionAction.done);
    expect(d.reason, 'F2: already handled');
    expect(d.did, 'opened PR #12');
    expect(d.target, 'inbox');
    expect(d.agent, 'codex');
  });

  test(
    'the database file is byte-identical and nothing else changes',
    () async {
      // AC-2
      // Rows live in the WAL until a checkpoint; fold them in so the main file
      // is what a reader sees, then hash every file the database owns.
      fx.db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
      String sha(String path) => File(path).existsSync()
          ? sha256.convert(File(path).readAsBytesSync()).toString()
          : 'absent';
      final List<String> owned = <String>[
        fx.dbPath,
        '${fx.dbPath}-wal',
        '${fx.dbPath}-shm',
      ];
      final List<String> before = owned.map(sha).toList();
      final Set<String> entries = fx.dir
          .listSync()
          .map((FileSystemEntity e) => p.basename(e.path))
          .toSet();

      // A real source this time: it must still not be read from or written to.
      await tools(
        allow: true,
        source: SqliteCaptureSource(
          dbPath: fx.dbPath,
          recordingsDir: fx.recordingsDir.path,
        ),
      ).call('submit_decision', args());

      expect(owned.map(sha).toList(), before);
      final Set<String> after = fx.dir
          .listSync()
          .map((FileSystemEntity e) => p.basename(e.path))
          .toSet();
      expect(after.difference(entries), <String>{'decisions'});
      expect(entries.difference(after), isEmpty);
    },
  );

  test('every action is accepted, an unknown one is not', () async {
    // AC-2
    for (final String action in <String>[
      'done',
      'route_file',
      'route_command',
      'skip',
    ]) {
      final Map<String, dynamic> r = await tools(allow: true).call(
        'submit_decision',
        args(more: <String, dynamic>{'action': action}),
      );
      expect(r['isError'], isNull, reason: action);
    }
    expect(files(), hasLength(4));
    for (final Object? bad in <Object?>[
      'delete',
      '',
      'DONE',
      'snooze_until',
      7,
    ]) {
      await expectLater(
        tools(
          allow: true,
        ).call('submit_decision', args(more: <String, dynamic>{'action': bad})),
        throwsA(isA<InvalidParams>()),
        reason: '$bad',
      );
    }
    expect(files(), hasLength(4));
  });

  test('an unsafe id is invalid params and writes nothing', () async {
    // AC-2
    for (final String bad in <String>['../x', '', 'a/b', r'a\b', '..', '.']) {
      await expectLater(
        tools(allow: true).call('submit_decision', args(id: bad)),
        throwsA(isA<InvalidParams>()),
        reason: '"$bad"',
      );
    }
    expect(files(), isEmpty);
  });

  test('missing or malformed required fields are invalid params', () async {
    // AC-2
    for (final String key in <String>['version', 'reason', 'agent']) {
      final Map<String, dynamic> a = args()..remove(key);
      await expectLater(
        tools(allow: true).call('submit_decision', a),
        throwsA(isA<InvalidParams>()),
        reason: 'missing $key',
      );
    }
    for (final Map<String, dynamic> bad in <Map<String, dynamic>>[
      <String, dynamic>{'agent': 'a b'},
      <String, dynamic>{'agent': 'x' * 41},
      <String, dynamic>{'agent': '../etc'},
      <String, dynamic>{'reason': 'r' * 2001},
      <String, dynamic>{'did': 'd' * 2001},
      <String, dynamic>{'version': ''},
    ]) {
      await expectLater(
        tools(allow: true).call('submit_decision', args(more: bad)),
        throwsA(isA<InvalidParams>()),
        reason: '$bad',
      );
    }
    expect(files(), isEmpty);
  });

  final Map<String, Map<String, dynamic>> refusedByApp =
      <String, Map<String, dynamic>>{
        'blank reason': <String, dynamic>{'reason': '   '},
        'newline-only reason': <String, dynamic>{'reason': '\n\t '},
        'blank version': <String, dynamic>{'version': ' '},
        'version of 129 chars': <String, dynamic>{'version': 'v' * 129},
        'reason of 2001 chars': <String, dynamic>{'reason': 'r' * 2001},
        'did of 2001 chars': <String, dynamic>{'did': 'd' * 2001},
        'target of 2001 chars': <String, dynamic>{'target': 't' * 2001},
      };
  for (final MapEntry<String, Map<String, dynamic>> c in refusedByApp.entries) {
    test(
      '${c.key}: invalid params and no file, as fromJson refuses it',
      () async {
        // AC-2
        Object? outcome;
        try {
          outcome = await tools(
            allow: true,
          ).call('submit_decision', args(more: c.value));
        } on InvalidParams catch (e) {
          outcome = e;
        }
        expect(outcome, isA<InvalidParams>(), reason: 'got $outcome');
        expect(files(), isEmpty);
      },
    );
  }

  test('every file the tool writes parses with fromJson', () async {
    // AC-2
    // Boundary values the app accepts: exactly at each limit.
    for (final Map<String, dynamic> ok in <Map<String, dynamic>>[
      <String, dynamic>{'version': 'v' * 128},
      <String, dynamic>{'reason': 'r' * 2000},
      <String, dynamic>{'did': 'd' * 2000, 'target': 't' * 2000},
    ]) {
      await tools(allow: true).call('submit_decision', args(more: ok));
    }
    expect(files(), hasLength(3));
    for (final File f in files()) {
      expect(
        AgentDecision.fromJson(jsonDecode(f.readAsStringSync())),
        isNotNull,
      );
    }
  });

  test(
    'a symlinked decisions directory is refused and its target untouched',
    () async {
      // AC-2
      final Directory outside = Directory.systemTemp.createTempSync('outside_');
      addTearDown(() => outside.deleteSync(recursive: true));
      Link(decisions.path).createSync(outside.path);

      Object? outcome;
      try {
        outcome = await tools(allow: true).call('submit_decision', args());
      } on InvalidParams catch (e) {
        outcome = e;
      }
      final bool refused =
          outcome is InvalidParams ||
          (outcome is Map<String, dynamic> && outcome['isError'] == true);
      expect(refused, isTrue, reason: 'got $outcome');
      expect(outside.listSync(), isEmpty);
    },
  );

  test('two submissions get distinct file names', () async {
    // AC-2
    await tools(allow: true).call('submit_decision', args());
    await tools(allow: true).call('submit_decision', args());
    expect(files().map((File f) => p.basename(f.path)).toSet(), hasLength(2));
  });
}
