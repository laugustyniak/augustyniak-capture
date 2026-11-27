import 'dart:convert';

import 'package:augustyniak_capture/features/mcp/data/sqlite_capture_source.dart';
import 'package:augustyniak_capture/features/mcp/domain/capture_tools.dart';
import 'package:augustyniak_capture/features/mcp/domain/mcp_server.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'mcp_fixture.dart';

String sha(String s) => sha256.convert(utf8.encode(s)).toString();

void main() {
  late McpFixture fx;

  setUp(() => fx = McpFixture());
  tearDown(() => fx.dispose());

  McpServer server() => McpServer(
    CaptureTools(
      SqliteCaptureSource(
        dbPath: fx.dbPath,
        recordingsDir: fx.recordingsDir.path,
      ),
    ),
  );

  Future<List<Map<String, dynamic>>> run(List<String> lines) async {
    final List<String> out = <String>[];
    await server().serve(Stream<String>.fromIterable(lines), out.add);
    return out
        .map((String l) => jsonDecode(l) as Map<String, dynamic>)
        .toList();
  }

  String req(String method, [Map<String, dynamic>? params]) =>
      jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 1,
        'method': method,
        'params': ?params,
      });

  Future<Map<String, dynamic>> rawCall(
    String name,
    Map<String, dynamic> args,
  ) async => (await run(<String>[
    req('tools/call', <String, dynamic>{'name': name, 'arguments': args}),
  ])).single;

  /// Successful tool result decoded: `{captures: [...], next?: ...}`.
  Future<Map<String, dynamic>> next([
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    final Map<String, dynamic> r = await rawCall('next_open_captures', args);
    expect(r['error'], isNull, reason: jsonEncode(r));
    final Map<String, dynamic> result = r['result'] as Map<String, dynamic>;
    expect(result['isError'], isNull, reason: jsonEncode(r));
    final String text =
        ((result['content'] as List).single as Map<String, dynamic>)['text']
            as String;
    return jsonDecode(text) as Map<String, dynamic>;
  }

  List<String> ids(Map<String, dynamic> page) => <String>[
    for (final dynamic c in page['captures'] as List)
      (c as Map<String, dynamic>)['id'] as String,
  ];

  DateTime day(int d) => DateTime.utc(2026, 2, d);

  test('lists only completed unprocessed captures', () async {
    // AC-2
    fx.insert(rec('ok', at: day(1)));
    fx.insert(rec('done', at: day(2), isProcessedByUser: true));
    fx.insert(rec('saved', at: day(3), status: RecordingStatus.saved));
    fx.insert(rec('failed', at: day(4), status: RecordingStatus.failed));
    fx.insert(
      rec('pending', at: day(5), status: RecordingStatus.pendingTranscription),
    );
    fx.insert(rec('busy', at: day(6), status: RecordingStatus.transcribing));
    expect(ids(await next()), <String>['ok']);
  });

  test('oldest first, ties broken by id', () async {
    // AC-1
    fx.insert(rec('b', at: day(5)));
    fx.insert(rec('a', at: day(5)));
    fx.insert(rec('z', at: day(1)));
    expect(ids(await next()), <String>['z', 'a', 'b']);
  });

  test('cursor pages without gaps or repeats', () async {
    // AC-1
    fx.insert(rec('e', at: day(3)));
    fx.insert(rec('c:2', at: day(2)));
    fx.insert(rec('a', at: day(1)));
    fx.insert(rec('d', at: day(3)));
    fx.insert(rec('b', at: day(2)));
    final List<String> seen = <String>[];
    String? after;
    int pages = 0;
    while (true) {
      final Map<String, dynamic> page = await next(<String, dynamic>{
        'limit': 2,
        'after': ?after,
      });
      seen.addAll(ids(page));
      pages++;
      expect(pages, lessThan(10));
      if (!page.containsKey('next')) {
        expect(ids(page), isNotEmpty);
        break;
      }
      expect(ids(page), hasLength(2));
      after = page['next'] as String;
    }
    expect(seen, <String>['a', 'b', 'c:2', 'd', 'e']);
    expect(pages, 3);
  });

  test('invalid cursor is an invalid-params error', () async {
    // AC-1
    // An unknown tool is also -32602, so prove the tool exists first.
    expect(await next(), contains('captures'));
    final String noColon = base64Url.encode(utf8.encode('abc'));
    final String emptyId = base64Url.encode(utf8.encode('1:'));
    final String badMs = base64Url.encode(utf8.encode('x:y'));
    for (final String bad in <String>['', '!!!', noColon, emptyId, badMs]) {
      final Map<String, dynamic> r = await rawCall(
        'next_open_captures',
        <String, dynamic>{'after': bad},
      );
      expect((r['error'] as Map)['code'], -32602, reason: 'after="$bad"');
    }
  });

  test('default limit is 10, limit above 100 is clamped', () async {
    // AC-1
    for (int i = 0; i < 105; i++) {
      fx.insert(
        rec(
          'r${i.toString().padLeft(3, '0')}',
          at: day(1).add(Duration(minutes: i)),
        ),
      );
    }
    final Map<String, dynamic> byDefault = await next();
    expect(ids(byDefault), hasLength(10));
    expect(byDefault, contains('next'));
    final Map<String, dynamic> big = await next(<String, dynamic>{
      'limit': 1000,
    });
    expect(ids(big), hasLength(100));
    expect(big, contains('next'));
  });

  test('project filter works by id and by name', () async {
    // AC-3
    fx.insertProject(projectA);
    fx.insert(rec('in', at: day(1), projectId: 'p-1'));
    fx.insert(rec('out', at: day(2)));
    expect(ids(await next(<String, dynamic>{'project': 'p-1'})), <String>[
      'in',
    ]);
    expect(
      ids(await next(<String, dynamic>{'project': 'ALPHA repo'})),
      <String>['in'],
    );
    expect(ids(await next()), <String>['in', 'out']);
    final Map<String, dynamic> r = await rawCall(
      'next_open_captures',
      <String, dynamic>{'project': 'nope'},
    );
    expect((r['result'] as Map)['isError'], true);
  });

  test(
    'version is the canonical sha256 of toJson and changes with it',
    () async {
      // AC-4 (#474): was sha256 of the stored payload bytes. The stored bytes
      // can differ from what the app re-encodes after a restart, so the token is
      // the canonical re-encoding on both sides.
      final Recording r = rec('v', at: day(1), transcript: 'hello');
      final String stored = '${jsonEncode(r.toJson())} ';
      fx.insert(r, payload: stored);
      final Map<String, dynamic> first =
          (await next())['captures'].single as Map<String, dynamic>;
      expect(first['version'], sha(jsonEncode(r.toJson())));
      expect(first['version'], isNot(sha(stored)));

      final Recording edited = rec('v', at: day(1), transcript: 'hello world');
      fx.db.execute(
        'UPDATE recordings SET json_payload = ? WHERE id = ?',
        <Object?>[jsonEncode(edited.toJson()), 'v'],
      );
      final Map<String, dynamic> second =
          (await next())['captures'].single as Map<String, dynamic>;
      expect(second['version'], sha(jsonEncode(edited.toJson())));
      expect(second['version'], isNot(first['version']));
    },
  );

  test('version of a degraded row uses re-encoded toJson', () async {
    // AC-4
    final Recording r = rec('d', at: day(1), transcript: 'from index');
    fx.insert(r, useJson: false);
    fx.writeJsonIndex(<Recording>[r]);
    final Map<String, dynamic> c =
        (await next())['captures'].single as Map<String, dynamic>;
    expect(c['transcript'], 'from index');
    expect(c['version'], sha(jsonEncode(r.toJson())));
  });

  test('a capture scheduled for the future is not in the queue', () async {
    // AC-3 (#474 gate rule): mirrors the desk filter, so an agent never
    // closes something the user parked until later.
    final DateTime future = DateTime.now().add(const Duration(days: 3));
    final DateTime past = DateTime.now().subtract(const Duration(days: 1));
    fx.insert(rec('later', at: day(1)).copyWith(resurfaceAt: future));
    fx.insert(rec('due', at: day(2)).copyWith(resurfaceAt: past));
    fx.insert(
      rec(
        'repeat-due',
        at: day(3),
      ).copyWith(resurfaceAt: past, repeatEveryDays: 7),
    );
    fx.insert(
      rec(
        'repeat-later',
        at: day(4),
      ).copyWith(resurfaceAt: future, repeatEveryDays: 7),
    );
    fx.insert(rec('plain', at: day(5)));
    expect(ids(await next()), <String>['due', 'repeat-due', 'plain']);
  });

  test('honours recordings.db-stale', () async {
    // AC-5
    fx.insert(rec('A', at: day(1)));
    fx.writeJsonIndex(<Recording>[rec('B', at: day(2))]);
    expect(ids(await next()), <String>['A']);
    fx.markStale();
    final Map<String, dynamic> page = await next();
    expect(ids(page), <String>['B']);
    expect(
      (page['captures'] as List).single['version'],
      sha(jsonEncode(rec('B', at: day(2)).toJson())),
    );
  });

  test('empty table falls back to the JSON index', () async {
    // AC-5
    fx.writeJsonIndex(<Recording>[rec('B', at: day(2))]);
    expect(ids(await next()), <String>['B']);
  });

  test('output carries no file paths and matches get_capture', () async {
    // AC-6
    fx.insert(
      rec('g', at: day(1), title: 'T', summary: 'S', transcript: 'full text'),
    );
    final List<Map<String, dynamic>> out = await run(<String>[
      req('tools/call', <String, dynamic>{
        'name': 'next_open_captures',
        'arguments': <String, dynamic>{},
      }),
    ]);
    final String all = jsonEncode(out);
    expect(all, isNot(contains('filePath')));
    expect(all, isNot(contains('/secret/path')));

    final Map<String, dynamic> c =
        (await next())['captures'].single as Map<String, dynamic>;
    final Map<String, dynamic> got = await rawCall(
      'get_capture',
      <String, dynamic>{'id': 'g'},
    );
    final Map<String, dynamic> expected =
        jsonDecode(
              (((got['result'] as Map)['content'] as List).single
                      as Map)['text']
                  as String,
            )
            as Map<String, dynamic>;
    expect(<String, dynamic>{...c}..remove('version'), expected);
    expect(c['version'], isA<String>());
  });

  test('tools/list advertises next_open_captures with its schema', () async {
    // AC-7
    final Map<String, dynamic> r = (await run(<String>[
      req('tools/list'),
    ])).single;
    final List<dynamic> tools = (r['result'] as Map)['tools'] as List<dynamic>;
    final Map<String, dynamic> tool =
        tools.singleWhere(
              (dynamic t) => (t as Map)['name'] == 'next_open_captures',
              orElse: () => <String, dynamic>{},
            )
            as Map<String, dynamic>;
    expect(tool, isNotEmpty);
    final Map<String, dynamic> schema =
        tool['inputSchema'] as Map<String, dynamic>;
    final Map<String, dynamic> props =
        schema['properties'] as Map<String, dynamic>;
    expect(props.keys, containsAll(<String>['limit', 'after', 'project']));
    expect(schema['required'] ?? <String>[], isEmpty);
    expect((props['limit'] as Map)['default'], 10);
    expect((props['limit'] as Map)['maximum'], 100);
  });
}
