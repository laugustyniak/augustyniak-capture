import 'dart:convert';

import 'package:augustyniak_capture/core/database/app_database.dart';
import 'package:augustyniak_capture/core/sync/turso_sync_service.dart';
import 'package:augustyniak_capture/features/projects/data/projects_repository.dart';
import 'package:augustyniak_capture/features/projects/domain/project.dart';
import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Database inMemoryDb;
  late AppDatabase appDb;

  setUp(() async {
    inMemoryDb = sqlite3.openInMemory();
    appDb = await AppDatabase.getInstance(overrideDb: inMemoryDb);
  });

  tearDown(() {
    inMemoryDb.dispose();
    AppDatabase.resetForTesting();
  });

  test('TursoSyncService pullFromTurso parses pipeline JSON into SQLite tables', () async {
    final MockClient mockClient = MockClient((http.Request request) async {
      expect(request.url.toString(), 'https://test-db.turso.io/v2/pipeline');
      expect(request.headers['Authorization'], 'Bearer test-token');

      final Map<String, dynamic> responseJson = <String, dynamic>{
        'results': <Map<String, dynamic>>[
          // 1. recordings
          <String, dynamic>{
            'type': 'ok',
            'response': <String, dynamic>{
              'type': 'execute',
              'result': <String, dynamic>{
                'cols': <Map<String, String>>[
                  <String, String>{'name': 'id'},
                  <String, String>{'name': 'file_path'},
                  <String, String>{'name': 'duration_ms'},
                  <String, String>{'name': 'type'},
                  <String, String>{'name': 'status'},
                  <String, String>{'name': 'category'},
                  <String, String>{'name': 'title'},
                  <String, String>{'name': 'summary'},
                  <String, String>{'name': 'tags_json'},
                  <String, String>{'name': 'created_at'},
                  <String, String>{'name': 'is_processed_by_user'},
                  <String, String>{'name': 'project_id'},
                  <String, String>{'name': 'failure_reason'},
                  <String, String>{'name': 'json_payload'},
                ],
                'rows': <List<Map<String, String>>>[
                  <Map<String, String>>[
                    <String, String>{'type': 'text', 'value': 'rec-101'},
                    <String, String>{'type': 'text', 'value': '/path/101.m4a'},
                    <String, String>{'type': 'integer', 'value': '45000'},
                    <String, String>{'type': 'text', 'value': 'audioRecording'},
                    <String, String>{'type': 'text', 'value': 'completed'},
                    <String, String>{'type': 'text', 'value': 'task'},
                    <String, String>{'type': 'text', 'value': 'Turso Test Note'},
                    <String, String>{'type': 'text', 'value': 'Summary of Turso test'},
                    <String, String>{'type': 'text', 'value': '["test","turso"]'},
                    <String, String>{'type': 'integer', 'value': '1700000000000'},
                    <String, String>{'type': 'integer', 'value': '1'},
                    <String, String>{'type': 'text', 'value': 'proj-1'},
                    <String, String>{'type': 'null', 'value': ''},
                    <String, String>{'type': 'null', 'value': ''},
                  ],
                ],
              },
            },
          },
          // 2. clipboard_items
          <String, dynamic>{
            'type': 'ok',
            'response': <String, dynamic>{
              'type': 'execute',
              'result': <String, dynamic>{
                'cols': <Map<String, String>>[],
                'rows': <List<Map<String, String>>>[
                  <Map<String, String>>[
                    <String, String>{'type': 'text', 'value': 'clip-1'},
                    <String, String>{'type': 'text', 'value': 'text'},
                    <String, String>{'type': 'text', 'value': 'Copied text from Mac'},
                    <String, String>{'type': 'null', 'value': ''},
                    <String, String>{'type': 'integer', 'value': '1700000000000'},
                    <String, String>{'type': 'text', 'value': 'Copied text preview'},
                    <String, String>{'type': 'text', 'value': '[]'},
                  ],
                ],
              },
            },
          },
          // 3. projects
          <String, dynamic>{
            'type': 'ok',
            'response': <String, dynamic>{
              'type': 'execute',
              'result': <String, dynamic>{
                'cols': <Map<String, String>>[],
                'rows': <List<Map<String, String>>>[
                  <Map<String, String>>[
                    <String, String>{'type': 'text', 'value': 'proj-1'},
                    <String, String>{'type': 'text', 'value': 'Augustyniak Capture'},
                    <String, String>{'type': 'text', 'value': '#0055FF'},
                    <String, String>{'type': 'text', 'value': '/path/app'},
                    <String, String>{'type': 'integer', 'value': '1700000000000'},
                  ],
                ],
              },
            },
          },
        ],
      };

      return http.Response(jsonEncode(responseJson), 200);
    });

    final TursoSyncService service = TursoSyncService(db: appDb, httpClient: mockClient);
    final bool ok = await service.pullFromTurso(
      dbUrl: 'libsql://test-db.turso.io',
      authToken: 'test-token',
    );

    expect(ok, isTrue);

    // Verify RecordingsRepository loads synced rec-101
    final RecordingsRepository recRepo = RecordingsRepository();
    final List<Recording> recordings = await recRepo.loadAll();
    expect(recordings.length, equals(1));
    expect(recordings.first.id, equals('rec-101'));
    expect(recordings.first.title, equals('Turso Test Note'));

    // Verify ProjectsRepository loads synced proj-1
    final ProjectsRepository projRepo = ProjectsRepository();
    final List<Project> projects = await projRepo.loadAll();
    expect(projects.length, equals(1));
    expect(projects.first.id, equals('proj-1'));
    expect(projects.first.name, equals('Augustyniak Capture'));
  });

  test('TursoSyncService pushToTurso sends local records to Turso Cloud', () async {
    // Insert a local project into appDb rawDb
    appDb.rawDb.execute('''
      INSERT INTO projects (id, name, color_hex, repository_path, created_at)
      VALUES ('local-p1', 'Local Android Project', '#FF5500', '/path/app', 1700000000000);
    ''');

    bool pushCalled = false;
    final MockClient mockClient = MockClient((http.Request request) async {
      pushCalled = true;
      final dynamic body = jsonDecode(request.body);
      expect(body['requests'], isNotNull);
      return http.Response('{"results": []}', 200);
    });

    final TursoSyncService service = TursoSyncService(db: appDb, httpClient: mockClient);
    final bool ok = await service.pushToTurso(
      dbUrl: 'libsql://test-db.turso.io',
      authToken: 'test-token',
    );

    expect(ok, isTrue);
    expect(pushCalled, isTrue);
  });
}
