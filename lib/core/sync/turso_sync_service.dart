import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:sqlite3/sqlite3.dart';
import '../../features/settings/domain/token_cipher.dart';
import '../database/app_database.dart';

class TursoSyncService {
  TursoSyncService({
    required AppDatabase db,
    http.Client? httpClient,
  })  : _db = db,
        _client = httpClient ?? http.Client();

  final AppDatabase _db;
  final http.Client _client;

  String _getPipelineEndpoint(String dbUrl) {
    String endpoint = dbUrl.trim();
    if (endpoint.startsWith('libsql://')) {
      endpoint = endpoint.replaceFirst('libsql://', 'https://');
    }
    if (!endpoint.endsWith('/v2/pipeline')) {
      endpoint = '$endpoint/v2/pipeline';
    }
    return endpoint;
  }

  static int _parseInteger(dynamic raw, int fallback) {
    if (raw == null) return fallback;
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return int.tryParse(raw.toString()) ?? fallback;
  }

  Future<bool> pullFromTurso({
    required String dbUrl,
    required String authToken,
  }) async {
    if (dbUrl.isEmpty || authToken.isEmpty || TokenCipher.isSealed(authToken)) return false;

    final String endpoint = _getPipelineEndpoint(dbUrl);

    try {
      final Map<String, dynamic> body = <String, dynamic>{
        'requests': <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'execute',
            'stmt': <String, dynamic>{
              'sql':
                  'SELECT id, file_path, duration_ms, type, status, category, title, summary, tags_json, created_at, is_processed_by_user, project_id, failure_reason, json_payload FROM recordings',
            },
          },
          <String, dynamic>{
            'type': 'execute',
            'stmt': <String, dynamic>{
              'sql':
                  'SELECT id, type, text, image_path, copied_at, preview, collections_json FROM clipboard_items',
            },
          },
          <String, dynamic>{
            'type': 'execute',
            'stmt': <String, dynamic>{
              'sql':
                  'SELECT id, name, color_hex, repository_path, created_at FROM projects',
            },
          },
        ],
      };

      final http.Response response = await _client.post(
        Uri.parse(endpoint),
        headers: <String, String>{
          'Authorization': 'Bearer $authToken',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(body),
      );

      if (response.statusCode != 200) {
        debugPrint('Turso Sync HTTP Error: ${response.statusCode} - ${response.body}');
        return false;
      }

      final dynamic resJson = jsonDecode(response.body);
      if (resJson is! Map<String, dynamic>) return false;
      final dynamic results = resJson['results'];
      if (results is! List<dynamic> || results.length < 3) return false;

      // 1. Recordings
      final dynamic recResult = results[0];
      if (recResult is Map<String, dynamic> && recResult['type'] == 'ok') {
        final dynamic responseObj = recResult['response'];
        if (responseObj is Map<String, dynamic> && responseObj['result'] is Map<String, dynamic>) {
          final dynamic resultObj = responseObj['result'];
          final dynamic rows = resultObj['rows'];
          if (rows is List<dynamic>) {
            final dynamic stmt = _db.rawDb.prepare('''
              INSERT OR REPLACE INTO recordings (
                id, file_path, duration_ms, type, status, category, title, summary, tags_json, created_at, is_processed_by_user, project_id, failure_reason, json_payload
              ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ''');
            for (final dynamic row in rows) {
              if (row is List<dynamic> && row.length >= 14) {
                stmt.execute(<Object?>[
                  row[0]?['value'],
                  row[1]?['value'],
                  _parseInteger(row[2]?['value'], 0),
                  row[3]?['value'],
                  row[4]?['value'],
                  row[5]?['value'],
                  row[6]?['value'],
                  row[7]?['value'],
                  row[8]?['value'] ?? '[]',
                  _parseInteger(row[9]?['value'], DateTime.now().millisecondsSinceEpoch),
                  _parseInteger(row[10]?['value'], 0),
                  row[11]?['value'],
                  row[12]?['value'],
                  row[13]?['value'],
                ]);
              }
            }
            stmt.dispose();
          }
        }
      }

      // 2. Clipboard Items
      final dynamic clipResult = results[1];
      if (clipResult is Map<String, dynamic> && clipResult['type'] == 'ok') {
        final dynamic responseObj = clipResult['response'];
        if (responseObj is Map<String, dynamic> && responseObj['result'] is Map<String, dynamic>) {
          final dynamic resultObj = responseObj['result'];
          final dynamic rows = resultObj['rows'];
          if (rows is List<dynamic>) {
            final dynamic stmt = _db.rawDb.prepare('''
              INSERT OR REPLACE INTO clipboard_items (
                id, type, text, image_path, copied_at, preview, collections_json
              ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ''');
            for (final dynamic row in rows) {
              if (row is List<dynamic> && row.length >= 7) {
                stmt.execute(<Object?>[
                  row[0]?['value'],
                  row[1]?['value'],
                  row[2]?['value'],
                  row[3]?['value'],
                  _parseInteger(row[4]?['value'], DateTime.now().millisecondsSinceEpoch),
                  row[5]?['value'],
                  row[6]?['value'] ?? '[]',
                ]);
              }
            }
            stmt.dispose();
          }
        }
      }

      // 3. Projects
      final dynamic projResult = results[2];
      if (projResult is Map<String, dynamic> && projResult['type'] == 'ok') {
        final dynamic responseObj = projResult['response'];
        if (responseObj is Map<String, dynamic> && responseObj['result'] is Map<String, dynamic>) {
          final dynamic resultObj = responseObj['result'];
          final dynamic rows = resultObj['rows'];
          if (rows is List<dynamic>) {
            final dynamic stmt = _db.rawDb.prepare('''
              INSERT OR REPLACE INTO projects (
                id, name, color_hex, repository_path, created_at
              ) VALUES (?, ?, ?, ?, ?)
            ''');
            for (final dynamic row in rows) {
              if (row is List<dynamic> && row.length >= 5) {
                stmt.execute(<Object?>[
                  row[0]?['value'],
                  row[1]?['value'],
                  row[2]?['value'] ?? '#000000',
                  row[3]?['value'],
                  _parseInteger(row[4]?['value'], DateTime.now().millisecondsSinceEpoch),
                ]);
              }
            }
            stmt.dispose();
          }
        }
      }

      debugPrint('⚡ Turso Sync Completed Successfully!');
      return true;
    } catch (e, st) {
      debugPrint('Turso Sync Exception: $e\n$st');
      return false;
    }
  }

  Future<bool> pushToTurso({
    required String dbUrl,
    required String authToken,
  }) async {
    if (dbUrl.isEmpty || authToken.isEmpty || TokenCipher.isSealed(authToken)) return false;

    final String endpoint = _getPipelineEndpoint(dbUrl);

    try {
      final List<Map<String, dynamic>> requests = <Map<String, dynamic>>[];

      final ResultSet recRows = _db.rawDb.select('''
        SELECT id, file_path, duration_ms, type, status, category, title, summary, tags_json, created_at, is_processed_by_user, project_id, failure_reason, json_payload
        FROM recordings;
      ''');

      for (final Row r in recRows) {
        requests.add(<String, dynamic>{
          'type': 'execute',
          'stmt': <String, dynamic>{
            'sql': '''
              INSERT OR REPLACE INTO recordings (
                id, file_path, duration_ms, type, status, category, title, summary, tags_json, created_at, is_processed_by_user, project_id, failure_reason, json_payload
              ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ''',
            'args': <Map<String, dynamic>>[
              <String, dynamic>{'type': 'text', 'value': r['id']},
              <String, dynamic>{'type': 'text', 'value': r['file_path']},
              <String, dynamic>{'type': 'integer', 'value': r['duration_ms'].toString()},
              <String, dynamic>{'type': 'text', 'value': r['type']},
              <String, dynamic>{'type': 'text', 'value': r['status']},
              <String, dynamic>{'type': 'text', 'value': r['category']},
              <String, dynamic>{'type': 'text', 'value': r['title']},
              <String, dynamic>{'type': 'text', 'value': r['summary']},
              <String, dynamic>{'type': 'text', 'value': r['tags_json'] ?? '[]'},
              <String, dynamic>{'type': 'integer', 'value': r['created_at'].toString()},
              <String, dynamic>{'type': 'integer', 'value': (r['is_processed_by_user'] == 1 ? 1 : 0).toString()},
              <String, dynamic>{'type': 'text', 'value': r['project_id']},
              <String, dynamic>{'type': 'text', 'value': r['failure_reason']},
              <String, dynamic>{'type': 'text', 'value': r['json_payload']},
            ],
          },
        });
      }

      final ResultSet clipRows = _db.rawDb.select('''
        SELECT id, type, text, image_path, copied_at, preview, collections_json FROM clipboard_items;
      ''');

      for (final Row c in clipRows) {
        requests.add(<String, dynamic>{
          'type': 'execute',
          'stmt': <String, dynamic>{
            'sql': '''
              INSERT OR REPLACE INTO clipboard_items (
                id, type, text, image_path, copied_at, preview, collections_json
              ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ''',
            'args': <Map<String, dynamic>>[
              <String, dynamic>{'type': 'text', 'value': c['id']},
              <String, dynamic>{'type': 'text', 'value': c['type']},
              <String, dynamic>{'type': 'text', 'value': c['text']},
              <String, dynamic>{'type': 'text', 'value': c['image_path']},
              <String, dynamic>{'type': 'integer', 'value': c['copied_at'].toString()},
              <String, dynamic>{'type': 'text', 'value': c['preview']},
              <String, dynamic>{'type': 'text', 'value': c['collections_json'] ?? '[]'},
            ],
          },
        });
      }

      final ResultSet projRows = _db.rawDb.select('''
        SELECT id, name, color_hex, repository_path, created_at FROM projects;
      ''');

      for (final Row p in projRows) {
        requests.add(<String, dynamic>{
          'type': 'execute',
          'stmt': <String, dynamic>{
            'sql': '''
              INSERT OR REPLACE INTO projects (
                id, name, color_hex, repository_path, created_at
              ) VALUES (?, ?, ?, ?, ?)
            ''',
            'args': <Map<String, dynamic>>[
              <String, dynamic>{'type': 'text', 'value': p['id']},
              <String, dynamic>{'type': 'text', 'value': p['name']},
              <String, dynamic>{'type': 'text', 'value': p['color_hex']},
              <String, dynamic>{'type': 'text', 'value': p['repository_path']},
              <String, dynamic>{'type': 'integer', 'value': p['created_at'].toString()},
            ],
          },
        });
      }

      if (requests.isEmpty) return true;

      final http.Response response = await _client.post(
        Uri.parse(endpoint),
        headers: <String, String>{
          'Authorization': 'Bearer $authToken',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(<String, dynamic>{'requests': requests}),
      );

      return response.statusCode == 200;
    } catch (e) {
      debugPrint('Turso Push Error: $e');
      return false;
    }
  }

  Future<bool> syncTwoWay({
    required String dbUrl,
    required String authToken,
  }) async {
    final bool pulled = await pullFromTurso(dbUrl: dbUrl, authToken: authToken);
    final bool pushed = await pushToTurso(dbUrl: dbUrl, authToken: authToken);
    return pulled && pushed;
  }
}
