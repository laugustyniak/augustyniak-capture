import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../database/app_database.dart';

class TursoSyncService {
  TursoSyncService({
    required AppDatabase db,
    http.Client? httpClient,
  })  : _db = db,
        _client = httpClient ?? http.Client();

  final AppDatabase _db;
  final http.Client _client;

  Future<bool> pullFromTurso({
    required String dbUrl,
    required String authToken,
  }) async {
    if (dbUrl.isEmpty || authToken.isEmpty) return false;

    // Convert libsql://... to https://...
    String endpoint = dbUrl.trim();
    if (endpoint.startsWith('libsql://')) {
      endpoint = endpoint.replaceFirst('libsql://', 'https://');
    }
    if (!endpoint.endsWith('/v2/pipeline')) {
      endpoint = '$endpoint/v2/pipeline';
    }

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
                  'SELECT id, title, description, color, created_at FROM projects',
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
                  row[2]?['value'],
                  row[3]?['value'],
                  row[4]?['value'],
                  row[5]?['value'],
                  row[6]?['value'],
                  row[7]?['value'],
                  row[8]?['value'] ?? '[]',
                  row[9]?['value'],
                  row[10]?['value'] ?? 0,
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
                  row[4]?['value'],
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
                id, title, description, color, created_at
              ) VALUES (?, ?, ?, ?, ?)
            ''');
            for (final dynamic row in rows) {
              if (row is List<dynamic> && row.length >= 5) {
                stmt.execute(<Object?>[
                  row[0]?['value'],
                  row[1]?['value'],
                  row[2]?['value'],
                  row[3]?['value'],
                  row[4]?['value'],
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
}
