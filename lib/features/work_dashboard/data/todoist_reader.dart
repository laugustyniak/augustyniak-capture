import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class TodoistProject {
  const TodoistProject({required this.id, required this.name});

  final String id;
  final String name;
}

class TodoistTask {
  const TodoistTask({
    required this.id,
    required this.content,
    required this.projectId,
    required this.priority,
    required this.labels,
    this.dueDate,
  });

  final String id;
  final String content;
  final String projectId;
  final int priority;
  final List<String> labels;
  final String? dueDate;

  Uri get url => Uri.parse('https://app.todoist.com/app/task/$id');

  factory TodoistTask.fromJson(Map<String, dynamic> json) {
    final Object? due = json['due'];
    return TodoistTask(
      id: json['id'] as String,
      content: json['content'] as String,
      projectId: json['project_id'] as String,
      priority: json['priority'] is int ? json['priority'] as int : 1,
      labels: (json['labels'] as List<dynamic>? ?? const <dynamic>[])
          .whereType<String>()
          .toList(growable: false),
      dueDate: due is Map<String, dynamic> ? due['date'] as String? : null,
    );
  }
}

class TodoistSnapshot {
  const TodoistSnapshot({
    required this.projects,
    required this.dueTasks,
    required this.founderTasks,
    required this.fetchedAt,
  });

  final List<TodoistProject> projects;
  final List<TodoistTask> dueTasks;
  final List<TodoistTask> founderTasks;
  final DateTime fetchedAt;
}

/// Reads Todoist API v1. It has no write methods or background polling.
class TodoistReader {
  TodoistReader({http.Client? client, Uri? baseUrl})
    : _client = client ?? http.Client(),
      _ownsClient = client == null,
      _baseUrl = baseUrl ?? Uri.parse('https://api.todoist.com/api/v1/');

  final http.Client _client;
  final bool _ownsClient;
  final Uri _baseUrl;

  void dispose() {
    if (_ownsClient) _client.close();
  }

  Future<TodoistSnapshot> load(String token) async {
    final List<Map<String, dynamic>> projectRows = await _pages(
      'projects',
      token,
    );
    final List<Map<String, dynamic>> dueRows = await _pages(
      'tasks/filter',
      token,
      query: 'today | overdue',
    );
    final List<Map<String, dynamic>> founderRows = await _pages(
      'tasks/filter',
      token,
      query: '@founder & (p1 | p2)',
    );
    return TodoistSnapshot(
      projects: projectRows
          .map(
            (Map<String, dynamic> row) => TodoistProject(
              id: row['id'] as String,
              name: row['name'] as String,
            ),
          )
          .toList(growable: false),
      dueTasks: dueRows.map(TodoistTask.fromJson).toList(growable: false),
      founderTasks: founderRows
          .map(TodoistTask.fromJson)
          .toList(growable: false),
      fetchedAt: DateTime.now(),
    );
  }

  Future<List<Map<String, dynamic>>> _pages(
    String path,
    String token, {
    String? query,
  }) async {
    final List<Map<String, dynamic>> rows = <Map<String, dynamic>>[];
    String? cursor;
    do {
      final Uri uri = _baseUrl
          .resolve(path)
          .replace(
            queryParameters: <String, String>{
              'limit': '200',
              'query': ?query,
              'cursor': ?cursor,
            },
          );
      final http.Response response;
      try {
        response = await _client
            .get(
              uri,
              headers: <String, String>{'Authorization': 'Bearer $token'},
            )
            .timeout(const Duration(seconds: 15));
      } on TimeoutException {
        throw const TodoistReadException(
          'Todoist did not respond. Try refreshing.',
        );
      }
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw const TodoistReadException('Todoist rejected the token.');
      }
      if (response.statusCode != 200) {
        throw TodoistReadException(
          'Todoist returned HTTP ${response.statusCode}.',
        );
      }
      final Object? decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic> || decoded['results'] is! List) {
        throw const TodoistReadException('Unexpected Todoist response.');
      }
      rows.addAll(
        (decoded['results'] as List<dynamic>).whereType<Map<String, dynamic>>(),
      );
      cursor = decoded['next_cursor'] as String?;
    } while (cursor != null && cursor.isNotEmpty);
    return rows;
  }
}

class TodoistReadException implements Exception {
  const TodoistReadException(this.message);

  final String message;

  @override
  String toString() => message;
}
