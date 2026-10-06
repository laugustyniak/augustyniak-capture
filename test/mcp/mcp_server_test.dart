import 'dart:async';
import 'dart:convert';

import 'package:augustyniak_capture/features/mcp/data/sqlite_capture_source.dart';
import 'package:augustyniak_capture/features/mcp/domain/capture_tools.dart';
import 'package:augustyniak_capture/features/mcp/domain/mcp_server.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/domain/route_record.dart';
import 'package:flutter_test/flutter_test.dart';

import 'mcp_fixture.dart';

void main() {
  late McpFixture fx;

  setUp(() {
    fx = McpFixture();
    fx.insertProject(projectA);
    fx.insert(
      rec(
        'c1',
        at: DateTime.utc(2026, 3, 1),
        title: 'Retry logic',
        summary: 'about OCR',
        transcript: 'We should add Exponential backoff ${'x' * 500}',
        tags: <String>['Backend'],
        projectId: 'p-1',
        routes: <RouteRecord>[
          RouteRecord(
            at: DateTime.utc(2026, 3, 2),
            kind: RouteKind.agent,
            target: 'codex',
            outcome: RouteOutcome(
              briefId: 'b',
              state: CommandState.done,
              checkedAt: DateTime.utc(2026, 3, 3),
              prUrl: 'https://github.com/x/y/pull/1',
            ),
          ),
        ],
      ),
    );
    fx.insert(
      rec(
        'c2',
        at: DateTime.utc(2025, 1, 1),
        title: 'Groceries',
        transcript: 'milk',
        status: RecordingStatus.failed,
      ),
    );
  });
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

  String req(int id, String method, [Map<String, dynamic>? params]) =>
      jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': ?params,
      });

  String call(int id, String name, Map<String, dynamic> args) =>
      req(id, 'tools/call', <String, dynamic>{'name': name, 'arguments': args});

  Map<String, dynamic> payload(Map<String, dynamic> response) {
    final Map<String, dynamic> result =
        response['result'] as Map<String, dynamic>;
    final List<dynamic> content = result['content'] as List<dynamic>;
    final String text =
        (content.single as Map<String, dynamic>)['text'] as String;
    return <String, dynamic>{
      'isError': result['isError'],
      // Failures carry a plain-text message, successes carry JSON.
      'data': result['isError'] == true ? text : jsonDecode(text),
    };
  }

  test('initialize echoes protocol and declares tools capability', () async {
    final Map<String, dynamic> r = (await run(<String>[
      req(1, 'initialize', <String, dynamic>{
        'protocolVersion': '2025-06-18',
        'capabilities': <String, dynamic>{},
        'clientInfo': <String, dynamic>{'name': 't', 'version': '1'},
      }),
    ])).single;
    final Map<String, dynamic> result = r['result'] as Map<String, dynamic>;
    expect(r['id'], 1);
    expect(result['protocolVersion'], '2025-06-18');
    expect(result['capabilities'], <String, dynamic>{
      'tools': <String, dynamic>{},
    });
    expect((result['serverInfo'] as Map)['name'], 'augustyniak-capture');
  });

  test('notification gets no response; ping answers', () async {
    final List<Map<String, dynamic>> out = await run(<String>[
      jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'method': 'notifications/initialized',
      }),
      req(2, 'ping'),
    ]);
    expect(out, hasLength(1));
    expect(out.single['id'], 2);
  });

  test('tools/list lists the three tools with input schemas', () async {
    final Map<String, dynamic> r = (await run(<String>[
      req(1, 'tools/list'),
    ])).single;
    final List<dynamic> tools = (r['result'] as Map)['tools'] as List<dynamic>;
    expect(tools.map((dynamic t) => (t as Map)['name']), <String>[
      'search_captures',
      'get_capture',
      'list_project_captures',
    ]);
    for (final dynamic t in tools) {
      expect((t as Map)['inputSchema'], isA<Map>());
    }
  });

  test(
    'search_captures: case-insensitive over transcript, truncated',
    () async {
      final Map<String, dynamic> p = payload(
        (await run(<String>[
          call(1, 'search_captures', <String, dynamic>{'query': 'EXPONENTIAL'}),
        ])).single,
      );
      final List<dynamic> data = p['data'] as List<dynamic>;
      expect(data, hasLength(1));
      final Map<String, dynamic> c = data.single as Map<String, dynamic>;
      expect(c['id'], 'c1');
      expect((c['transcript'] as String).length, lessThan(400));
      expect(c['project'], <String, dynamic>{
        'id': 'p-1',
        'name': 'Alpha Repo',
      });
      final Map<String, dynamic> route =
          (c['routes'] as List).single as Map<String, dynamic>;
      expect(route['kind'], 'agent');
      expect(
        route['outcome'],
        containsPair('prUrl', 'https://github.com/x/y/pull/1'),
      );
    },
  );

  test(
    'search matches title, tags; filters by project name and since',
    () async {
      Future<int> count(Map<String, dynamic> args) async {
        final Map<String, dynamic> p = payload(
          (await run(<String>[call(1, 'search_captures', args)])).single,
        );
        return (p['data'] as List).length;
      }

      expect(await count(<String, dynamic>{'query': 'groceries'}), 1);
      expect(await count(<String, dynamic>{'query': 'backend'}), 1);
      expect(
        await count(<String, dynamic>{'query': 'e', 'project': 'alpha repo'}),
        1,
      );
      expect(await count(<String, dynamic>{'query': 'e', 'project': 'p-1'}), 1);
      expect(
        await count(<String, dynamic>{'query': 'o', 'since': '2026-01-01'}),
        1,
      );
      expect(await count(<String, dynamic>{'query': 'e', 'limit': 1}), 1);
    },
  );

  test('output never contains path keys or values', () async {
    final List<Map<String, dynamic>> out = await run(<String>[
      call(1, 'get_capture', <String, dynamic>{'id': 'c1'}),
      call(2, 'search_captures', <String, dynamic>{'query': 'e'}),
    ]);
    final String all = jsonEncode(out);
    expect(all, isNot(contains('filePath')));
    expect(all, isNot(contains('/secret/path')));
    expect(all, isNot(contains('artifacts')));
    expect(all, isNot(contains('thumbPath')));
  });

  test('get_capture returns the full transcript and omits null keys', () async {
    final Map<String, dynamic> p = payload(
      (await run(<String>[
        call(1, 'get_capture', <String, dynamic>{'id': 'c1'}),
      ])).single,
    );
    final Map<String, dynamic> c = p['data'] as Map<String, dynamic>;
    expect((c['transcript'] as String).length, greaterThan(500));
    final Map<String, dynamic> bare =
        payload(
              (await run(<String>[
                call(1, 'get_capture', <String, dynamic>{'id': 'c2'}),
              ])).single,
            )['data']
            as Map<String, dynamic>;
    expect(bare.containsKey('summary'), isFalse);
    expect(bare.containsKey('project'), isFalse);
  });

  test('get_capture on an unknown id is a tool error', () async {
    final Map<String, dynamic> p = payload(
      (await run(<String>[
        call(1, 'get_capture', <String, dynamic>{'id': 'zzz'}),
      ])).single,
    );
    expect(p['isError'], isTrue);
  });

  test('list_project_captures filters by project and status', () async {
    final Map<String, dynamic> p = payload(
      (await run(<String>[
        call(1, 'list_project_captures', <String, dynamic>{
          'project': 'Alpha Repo',
          'status': 'completed',
        }),
      ])).single,
    );
    expect((p['data'] as List), hasLength(1));
    final Map<String, dynamic> none = payload(
      (await run(<String>[
        call(1, 'list_project_captures', <String, dynamic>{
          'project': 'Alpha Repo',
          'status': 'failed',
        }),
      ])).single,
    );
    expect(none['data'], isEmpty);
  });

  test('unknown project is a tool error', () async {
    final Map<String, dynamic> p = payload(
      (await run(<String>[
        call(1, 'list_project_captures', <String, dynamic>{'project': 'nope'}),
      ])).single,
    );
    expect(p['isError'], isTrue);
  });

  test('unknown tool and bad params are -32602', () async {
    final List<Map<String, dynamic>> out = await run(<String>[
      call(1, 'nope', <String, dynamic>{}),
      call(2, 'search_captures', <String, dynamic>{}),
      call(3, 'search_captures', <String, dynamic>{'query': 'a', 'limit': 'x'}),
    ]);
    for (final Map<String, dynamic> r in out) {
      expect((r['error'] as Map)['code'], -32602);
    }
  });

  test('unknown method is -32601', () async {
    final Map<String, dynamic> r = (await run(<String>[
      req(1, 'bogus'),
    ])).single;
    expect((r['error'] as Map)['code'], -32601);
  });

  test('malformed line is -32700 and the loop keeps serving', () async {
    final List<Map<String, dynamic>> out = await run(<String>[
      '{broken',
      '',
      '[1,2]',
      req(5, 'ping'),
    ]);
    expect((out[0]['error'] as Map)['code'], -32700);
    expect(out[0]['id'], isNull);
    expect((out[1]['error'] as Map)['code'], -32600);
    expect(out[2]['id'], 5);
  });

  test(
    'missing database yields isError and the server keeps running',
    () async {
      final List<String> out = <String>[];
      await McpServer(
        CaptureTools(
          SqliteCaptureSource(
            dbPath: '${fx.dir.path}/none.sqlite',
            recordingsDir: '${fx.dir.path}/none',
          ),
        ),
      ).serve(
        Stream<String>.fromIterable(<String>[
          call(1, 'get_capture', <String, dynamic>{'id': 'a'}),
          req(2, 'ping'),
        ]),
        out.add,
      );
      expect(out, hasLength(2));
      expect(
        payload(jsonDecode(out[0]) as Map<String, dynamic>)['isError'],
        isTrue,
      );
    },
  );
}
