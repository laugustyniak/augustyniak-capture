import 'dart:convert';

import 'package:augustyniak_capture/core/database/app_database.dart';
import 'package:augustyniak_capture/core/sync/turso_sync_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';

/// The pipeline protocol types every bound parameter, and a NULL column has a
/// type of its own. Getting that wrong is not a per-row problem: the server
/// rejects the **entire** batch with a 400 before executing anything, so one
/// capture with no title stops the whole queue from reaching the cloud.
void main() {
  group('TursoSyncService.encodeArg', () {
    test('a null column is sent as the null type, never as a null string', () {
      // The regression. Sending {'type': 'text', 'value': null} answered
      // "JSON parse error: invalid type: null, expected a string" for the
      // whole request — and pushToTurso reports that as a plain false, with
      // the pull half of syncTwoWay still printing its success line.
      expect(TursoSyncService.encodeArg(null), <String, dynamic>{'type': 'null'});
      expect(
        TursoSyncService.encodeArg(null, integer: true),
        <String, dynamic>{'type': 'null'},
      );
    });

    test('text is passed through as text', () {
      expect(
        TursoSyncService.encodeArg('abc'),
        <String, dynamic>{'type': 'text', 'value': 'abc'},
      );
    });

    test('integers are stringified, as the protocol requires', () {
      expect(
        TursoSyncService.encodeArg(42, integer: true),
        <String, dynamic>{'type': 'integer', 'value': '42'},
      );
    });

    test('an empty string is a value, not a null', () {
      // '' and null mean different things in a column that holds a title.
      expect(
        TursoSyncService.encodeArg(''),
        <String, dynamic>{'type': 'text', 'value': ''},
      );
    });

    test('zero is a value, not a null', () {
      expect(
        TursoSyncService.encodeArg(0, integer: true),
        <String, dynamic>{'type': 'integer', 'value': '0'},
      );
    });
  });

  /// Whoever answers the pipeline request decides what these rows say, and the
  /// app acts on them: it deletes `file_path`, hands it to the OS opener, and
  /// copies it into the note vault. A pull is therefore an *untrusted* input,
  /// however familiar the tables look.
  group('TursoSyncService.pullFromTurso', () {
    const String recordingsDir = '/local/recordings';

    late Database db;

    setUp(() async {
      AppDatabase.resetForTesting();
      db = sqlite3.openInMemory();
      await AppDatabase.getInstance(overrideDb: db);
    });

    tearDown(() => AppDatabase.resetForTesting());

    Map<String, dynamic> cell(Object? value) =>
        <String, dynamic>{'value': value};

    Map<String, dynamic> ok(List<List<Map<String, dynamic>>> rows) =>
        <String, dynamic>{
          'type': 'ok',
          'response': <String, dynamic>{
            'result': <String, dynamic>{'rows': rows},
          },
        };

    /// One pipeline answer: recordings, clipboard items, projects.
    String answer({
      List<List<Map<String, dynamic>>> recordings = const <List<Map<String, dynamic>>>[],
      List<List<Map<String, dynamic>>> clipboard = const <List<Map<String, dynamic>>>[],
      List<List<Map<String, dynamic>>> projects = const <List<Map<String, dynamic>>>[],
    }) => jsonEncode(<String, dynamic>{
      'results': <Map<String, dynamic>>[
        ok(recordings),
        ok(clipboard),
        ok(projects),
      ],
    });

    List<Map<String, dynamic>> recordingRow({
      required String id,
      required String filePath,
      String? jsonPayload,
    }) => <Map<String, dynamic>>[
      cell(id),
      cell(filePath),
      cell('1000'),
      cell('audioRecording'),
      cell('completed'),
      cell(null),
      cell('Title'),
      cell(null),
      cell('[]'),
      cell('1754000000000'),
      cell('0'),
      cell(null),
      cell(null),
      cell(jsonPayload),
    ];

    test('a remote source path contributes its name, not its location', () async {
      final AppDatabase database = await AppDatabase.getInstance();
      final TursoSyncService service = TursoSyncService(
        db: database,
        httpClient: MockClient(
          (http.Request request) async => http.Response(
            answer(
              recordings: <List<Map<String, dynamic>>>[
                recordingRow(
                  id: 'a',
                  filePath: '/Users/attacker/Documents/recordings/a.m4a',
                ),
              ],
            ),
            200,
          ),
        ),
        recordingsDirectory: () async => recordingsDir,
      );

      expect(
        await service.pullFromTurso(
          dbUrl: 'libsql://db-me.turso.io',
          authToken: 'token',
        ),
        isTrue,
      );

      final ResultSet rows = database.rawDb.select(
        'SELECT file_path FROM recordings WHERE id = ?',
        <Object?>['a'],
      );
      expect(rows.single['file_path'], '$recordingsDir/a.m4a');
    });

    test('the payload copy of the path is re-rooted too', () async {
      // `RecordingsRepository.loadAll` prefers `json_payload`, so this is the
      // half that decides what `deleteArtifacts` and `openSource` receive.
      final AppDatabase database = await AppDatabase.getInstance();
      final String payload = jsonEncode(<String, dynamic>{
        'id': 'a',
        'filePath': '/Users/attacker/.ssh/id_rsa',
        'createdAt': '2026-08-01T10:00:00.000',
        'durationMs': 1000,
        'status': 'completed',
        'type': 'audioRecording',
        'tags': <String>[],
        'isProcessedByUser': false,
        'artifacts': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'x', 'path': '/Applications/Calculator.app'},
        ],
      });
      final TursoSyncService service = TursoSyncService(
        db: database,
        httpClient: MockClient(
          (http.Request request) async => http.Response(
            answer(
              recordings: <List<Map<String, dynamic>>>[
                recordingRow(id: 'a', filePath: 'a.m4a', jsonPayload: payload),
              ],
            ),
            200,
          ),
        ),
        recordingsDirectory: () async => recordingsDir,
      );

      await service.pullFromTurso(
        dbUrl: 'libsql://db-me.turso.io',
        authToken: 'token',
      );

      final ResultSet rows = database.rawDb.select(
        'SELECT json_payload FROM recordings WHERE id = ?',
        <Object?>['a'],
      );
      final Map<String, dynamic> stored =
          jsonDecode(rows.single['json_payload'] as String)
              as Map<String, dynamic>;
      expect(stored['filePath'], '$recordingsDir/id_rsa');
      expect(stored['artifacts'], isEmpty);
    });

    test('a clipboard row cannot name a local image file', () async {
      // Nothing syncs the PNG itself, so a remote `image_path` can only ever
      // be a delete target for `clearHistory` and eviction.
      final AppDatabase database = await AppDatabase.getInstance();
      final TursoSyncService service = TursoSyncService(
        db: database,
        httpClient: MockClient(
          (http.Request request) async => http.Response(
            answer(
              clipboard: <List<Map<String, dynamic>>>[
                <Map<String, dynamic>>[
                  cell('c1'),
                  cell('image'),
                  cell(null),
                  cell('/Users/me/Documents/important.png'),
                  cell('1754000000000'),
                  cell('[Image]'),
                  cell('[]'),
                ],
              ],
            ),
            200,
          ),
        ),
        recordingsDirectory: () async => recordingsDir,
      );

      await service.pullFromTurso(
        dbUrl: 'libsql://db-me.turso.io',
        authToken: 'token',
      );

      final ResultSet rows = database.rawDb.select(
        'SELECT image_path FROM clipboard_items WHERE id = ?',
        <Object?>['c1'],
      );
      expect(rows.single['image_path'], isNull);
    });

    test('a pulled project never repoints an existing repository path', () async {
      // `repoPath` drives reading CLAUDE.md into an LLM prompt, appending to
      // inbox.md and starting an agent CLI in that directory.
      final AppDatabase database = await AppDatabase.getInstance();
      database.rawDb.execute(
        'INSERT INTO projects (id, name, color_hex, repository_path, created_at) '
        'VALUES (?, ?, ?, ?, ?)',
        <Object?>['p1', 'Mine', '#000000', '/Users/me/code/mine', 1],
      );

      final TursoSyncService service = TursoSyncService(
        db: database,
        httpClient: MockClient(
          (http.Request request) async => http.Response(
            answer(
              projects: <List<Map<String, dynamic>>>[
                <Map<String, dynamic>>[
                  cell('p1'),
                  cell('Renamed'),
                  cell('#111111'),
                  cell('/Users/me/.ssh'),
                  cell('2'),
                ],
              ],
            ),
            200,
          ),
        ),
        recordingsDirectory: () async => recordingsDir,
      );

      await service.pullFromTurso(
        dbUrl: 'libsql://db-me.turso.io',
        authToken: 'token',
      );

      final Row row = database.rawDb
          .select('SELECT name, repository_path FROM projects WHERE id = ?', <Object?>[
            'p1',
          ])
          .single;
      // The name is shared data and updates; the path is a fact about this
      // machine and does not.
      expect(row['name'], 'Renamed');
      expect(row['repository_path'], '/Users/me/code/mine');
    });

    test('a project arriving for the first time carries no repository path', () async {
      final AppDatabase database = await AppDatabase.getInstance();
      final TursoSyncService service = TursoSyncService(
        db: database,
        httpClient: MockClient(
          (http.Request request) async => http.Response(
            answer(
              projects: <List<Map<String, dynamic>>>[
                <Map<String, dynamic>>[
                  cell('p2'),
                  cell('Theirs'),
                  cell('#222222'),
                  cell('/Users/attacker/payload'),
                  cell('2'),
                ],
              ],
            ),
            200,
          ),
        ),
        recordingsDirectory: () async => recordingsDir,
      );

      await service.pullFromTurso(
        dbUrl: 'libsql://db-me.turso.io',
        authToken: 'token',
      );

      final Row row = database.rawDb
          .select('SELECT repository_path FROM projects WHERE id = ?', <Object?>[
            'p2',
          ])
          .single;
      expect(row['repository_path'], isNull);
    });

    test('a server that never answers does not hang the pull', () async {
      // Every other HTTP call in this app is bounded — `HttpVisionOcrService`
      // times out at two minutes precisely so a hung request cannot stall the
      // single-flight drain. The sync had no bound at all, and it is kicked
      // from `initialize()`.
      final AppDatabase database = await AppDatabase.getInstance();
      final TursoSyncService service = TursoSyncService(
        db: database,
        httpClient: MockClient((http.Request request) async {
          await Future<void>.delayed(const Duration(milliseconds: 400));
          return http.Response(answer(), 200);
        }),
        recordingsDirectory: () async => recordingsDir,
        requestTimeout: const Duration(milliseconds: 20),
      );

      expect(
        await service.pullFromTurso(
          dbUrl: 'libsql://db-me.turso.io',
          authToken: 'token',
        ),
        isFalse,
      );
    });

    test('a failed response is logged without its body', () async {
      // The body of a pipeline response is rows: titles, transcripts, clipboard
      // text. `debugPrint` survives in release builds, so printing it puts the
      // user's notes in the system log.
      final List<String?> printed = <String?>[];
      final DebugPrintCallback original = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) => printed.add(message);
      addTearDown(() => debugPrint = original);

      final AppDatabase database = await AppDatabase.getInstance();
      final TursoSyncService service = TursoSyncService(
        db: database,
        httpClient: MockClient(
          (http.Request request) async =>
              http.Response('{"rows":[["a dictated secret"]]}', 500),
        ),
        recordingsDirectory: () async => recordingsDir,
      );

      await service.pullFromTurso(
        dbUrl: 'libsql://db-me.turso.io',
        authToken: 'token',
      );

      expect(printed.join('\n'), isNot(contains('a dictated secret')));
      // The status code is what a reader needs, and it names no content.
      expect(printed.join('\n'), contains('500'));
    });

    test('an http address is refused before the token is sent', () async {
      final AppDatabase database = await AppDatabase.getInstance();
      final List<Uri> calls = <Uri>[];
      final TursoSyncService service = TursoSyncService(
        db: database,
        httpClient: MockClient((http.Request request) async {
          calls.add(request.url);
          return http.Response(answer(), 200);
        }),
        recordingsDirectory: () async => recordingsDir,
      );

      expect(
        await service.pullFromTurso(
          dbUrl: 'http://db-me.turso.io',
          authToken: 'token',
        ),
        isFalse,
      );
      // The point is not the false — it is that nothing left the machine.
      expect(calls, isEmpty);
    });
  });
}
