import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:augustyniak_capture/features/work_dashboard/data/todoist_reader.dart';

void main() {
  test('reads every API page and keeps the token out of URLs', () async {
    final List<Uri> urls = <Uri>[];
    final MockClient client = MockClient((http.Request request) async {
      urls.add(request.url);
      expect(request.method, 'GET');
      expect(request.headers['Authorization'], 'Bearer secret-token');
      final String path = request.url.path;
      if (path.endsWith('/projects')) {
        return http.Response(
          jsonEncode(<String, Object?>{
            'results': <Object>[
              <String, String>{'id': 'p1', 'name': 'Buy-It.ai'},
            ],
            'next_cursor': null,
          }),
          200,
        );
      }
      if (request.url.queryParameters['query'] == 'today | overdue') {
        return http.Response(
          jsonEncode(<String, Object?>{
            'results': <Object>[
              <String, Object?>{
                'id': 't1',
                'content': 'First action',
                'project_id': 'p1',
                'priority': 4,
                'labels': <String>['founder'],
                'due': <String, String>{'date': '2026-10-06'},
              },
            ],
            'next_cursor': request.url.queryParameters['cursor'] == null
                ? 'next-page'
                : null,
          }),
          200,
        );
      }
      return http.Response(
        jsonEncode(<String, Object?>{
          'results': <Object>[],
          'next_cursor': null,
        }),
        200,
      );
    });
    final TodoistReader reader = TodoistReader(
      client: client,
      baseUrl: Uri.parse('https://api.todoist.test/api/v1/'),
    );

    final TodoistSnapshot snapshot = await reader.load('secret-token');

    expect(snapshot.projects.single.name, 'Buy-It.ai');
    expect(snapshot.dueTasks.length, 2);
    expect(snapshot.dueTasks.first.dueDate, '2026-10-06');
    expect(snapshot.dueTasks.first.url.host, 'app.todoist.com');
    expect(urls.length, 4);
    expect(
      urls.every((Uri uri) => !uri.toString().contains('secret-token')),
      isTrue,
    );
  });

  test('rejects invalid token without leaking it in the error', () async {
    final TodoistReader reader = TodoistReader(
      client: MockClient(
        (http.Request request) async => http.Response('', 401),
      ),
    );
    expect(
      reader.load('private-token'),
      throwsA(
        isA<TodoistReadException>().having(
          (TodoistReadException error) => error.toString(),
          'message',
          isNot(contains('private-token')),
        ),
      ),
    );
  });
}
