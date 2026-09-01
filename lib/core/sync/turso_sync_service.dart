import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import '../../features/settings/domain/token_cipher.dart';
import '../database/app_database.dart';
import 'sync_endpoint.dart';
import 'sync_path_policy.dart';

class TursoSyncService {
  TursoSyncService({
    required AppDatabase db,
    http.Client? httpClient,
    Future<String> Function()? recordingsDirectory,
    Duration requestTimeout = defaultRequestTimeout,
  }) : _db = db,
       _client = httpClient ?? http.Client(),
       _recordingsDirectory =
           recordingsDirectory ?? _defaultRecordingsDirectory,
       _requestTimeout = requestTimeout;

  /// How long a pipeline call may take before it is abandoned.
  ///
  /// There was no bound at all, and this is not a background nicety: the pull
  /// is kicked from `RecordingsController.initialize()`, so a server that
  /// accepts a connection and then says nothing left that await outstanding for
  /// as long as the socket stayed open. Same reasoning and the same shape as
  /// `HttpVisionOcrService.requestTimeout`; longer, because a full push can
  /// carry the whole queue.
  static const Duration defaultRequestTimeout = Duration(seconds: 60);

  final Duration _requestTimeout;

  final AppDatabase _db;
  final http.Client _client;

  /// Where a pulled source file would live **on this machine**. Injectable so
  /// the pull can be tested without `path_provider`, and read through a
  /// callback because it is only needed once a row actually arrives.
  final Future<String> Function() _recordingsDirectory;

  String? _failureReason;

  /// A safe explanation for the most recent failed operation. This never
  /// includes the bearer token or a response body, because both may contain
  /// secrets or synced user content.
  String? get failureReason => _failureReason;

  static Future<String> _defaultRecordingsDirectory() async {
    final Directory documents = await getApplicationDocumentsDirectory();
    return p.join(documents.path, 'recordings');
  }

  /// Encode one bound parameter for the libsql pipeline protocol.
  ///
  /// **A NULL column has a type of its own and must be sent as
  /// `{'type': 'null'}`.** Sending `{'type': 'text', 'value': null}` makes the
  /// server answer `JSON parse error: invalid type: null, expected a string`
  /// and reject the **whole** request before executing any of it — so a single
  /// capture with no title, category or project keeps the entire queue out of
  /// the cloud. Every row here has at least one nullable column, which is why
  /// the push had never once succeeded.
  ///
  /// It failed quietly: `pushToTurso` turns a non-200 into a bare `false`, and
  /// `syncTwoWay` is `pulled && pushed`, so the pull half still printed its
  /// success line while nothing was uploaded.
  @visibleForTesting
  static Map<String, dynamic> encodeArg(Object? value, {bool integer = false}) {
    if (value == null) return <String, dynamic>{'type': 'null'};
    return <String, dynamic>{
      'type': integer ? 'integer' : 'text',
      'value': value.toString(),
    };
  }

  /// The pipeline URL for [dbUrl], or null when this address must not receive
  /// a request.
  ///
  /// **Only `libsql://` used to be rewritten**, so an `http://` address was
  /// carried through untouched and every call sent `Authorization: Bearer …`
  /// plus the whole batch of captures in the clear. [SyncEndpoint] is the one
  /// place that decision is now made, for the manual Config-tab entry and the
  /// QR pairing alike.
  String? _getPipelineEndpoint(String dbUrl) {
    final String? accepted = SyncEndpoint.normalize(dbUrl);
    if (accepted == null) return null;
    String endpoint = accepted;
    if (endpoint.startsWith('libsql://')) {
      endpoint = endpoint.replaceFirst('libsql://', 'https://');
    }
    if (!endpoint.endsWith('/v2/pipeline')) {
      endpoint = '$endpoint/v2/pipeline';
    }
    return endpoint;
  }

  /// The row's `json_payload` with its paths re-rooted, or null to fall back on
  /// the columns.
  ///
  /// Null covers "unparseable" as well as "unsafe", and both are safe answers:
  /// `RecordingsRepository.loadAll` only prefers the payload when it is there
  /// and parses, and rebuilds the recording from the sanitised columns
  /// otherwise. Storing a payload this method could not vet would hand the
  /// loader the one copy that bypasses every check above it.
  static String? _sanitizedPayload(Object? raw, String recordingsDirectory) {
    if (raw is! String || raw.isEmpty) return null;
    try {
      final dynamic decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final Map<String, dynamic>? clean = SyncPathPolicy.sanitizePayload(
        decoded,
        recordingsDirectory: recordingsDirectory,
      );
      return clean == null ? null : jsonEncode(clean);
    } catch (_) {
      return null;
    }
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
    if (dbUrl.isEmpty || authToken.isEmpty || TokenCipher.isSealed(authToken)) {
      _fail('Turso credentials are missing or unavailable.');
      return false;
    }

    final String? endpoint = _getPipelineEndpoint(dbUrl);
    if (endpoint == null) {
      _fail('Turso database URL must be an https:// or libsql:// address.');
      return false;
    }
    // Resolved before the request, so a row can be re-rooted the moment it
    // arrives rather than trusted for the length of a directory lookup.
    final String localRecordings = await _recordingsDirectory();

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

      final http.Response response = await _client
          .post(
            Uri.parse(endpoint),
            headers: <String, String>{
              'Authorization': 'Bearer $authToken',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(_requestTimeout);

      if (response.statusCode != 200) {
        // The status code, never the body. A pipeline response *is* the
        // user's rows — titles, transcripts, clipboard text — and `debugPrint`
        // survives in release builds, so printing it copies the notes into the
        // system log where nothing this app owns can ever remove them.
        _fail(_statusReason('pull', response.statusCode));
        return false;
      }

      final dynamic resJson = jsonDecode(response.body);
      if (resJson is! Map<String, dynamic>) {
        _fail('Turso pull returned an invalid response.');
        return false;
      }
      final dynamic results = resJson['results'];
      if (results is! List<dynamic> || results.length < 3) {
        _fail('Turso pull returned an incomplete response.');
        return false;
      }

      // 1. Recordings
      final dynamic recResult = results[0];
      if (recResult is Map<String, dynamic> && recResult['type'] == 'ok') {
        final dynamic responseObj = recResult['response'];
        if (responseObj is Map<String, dynamic> &&
            responseObj['result'] is Map<String, dynamic>) {
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
                // A remote row may name a file, never a place — see
                // [SyncPathPolicy]. A row with no usable name is dropped
                // rather than stored pointing at somebody else's disk.
                final String? name = SyncPathPolicy.localFileName(
                  row[1]?['value'],
                );
                if (name == null) continue;
                final String? payload = _sanitizedPayload(
                  row[13]?['value'],
                  localRecordings,
                );

                stmt.execute(<Object?>[
                  row[0]?['value'],
                  p.join(localRecordings, name),
                  _parseInteger(row[2]?['value'], 0),
                  row[3]?['value'],
                  row[4]?['value'],
                  row[5]?['value'],
                  row[6]?['value'],
                  row[7]?['value'],
                  row[8]?['value'] ?? '[]',
                  _parseInteger(
                    row[9]?['value'],
                    DateTime.now().millisecondsSinceEpoch,
                  ),
                  _parseInteger(row[10]?['value'], 0),
                  row[11]?['value'],
                  row[12]?['value'],
                  payload,
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
        if (responseObj is Map<String, dynamic> &&
            responseObj['result'] is Map<String, dynamic>) {
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
                  // The PNG itself is not synced, so a remote `image_path`
                  // can only ever name a *local* file — and all three ways a
                  // clipboard row leaves (delete, clear, eviction) delete
                  // whatever it names. The text and preview still travel.
                  null,
                  _parseInteger(
                    row[4]?['value'],
                    DateTime.now().millisecondsSinceEpoch,
                  ),
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
        if (responseObj is Map<String, dynamic> &&
            responseObj['result'] is Map<String, dynamic>) {
          final dynamic resultObj = responseObj['result'];
          final dynamic rows = resultObj['rows'];
          if (rows is List<dynamic>) {
            // `repository_path` is deliberately absent from both halves.
            //
            // It is a fact about *this* machine, and it is the most powerful
            // field in the pull: `ProjectContextReader` reads a file from that
            // directory into an LLM prompt, `ProjectInboxRouter` appends to
            // `inbox.md` inside it, and the agent handoff writes there and
            // starts a CLI with it as the working directory. A path from
            // another machine cannot be meaningful here and must not be
            // actionable, so a synced project keeps the local path it already
            // had, and a new one arrives with none until the user picks one.
            final dynamic stmt = _db.rawDb.prepare('''
              INSERT INTO projects (
                id, name, color_hex, repository_path, created_at
              ) VALUES (?, ?, ?, NULL, ?)
              ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                color_hex = excluded.color_hex,
                created_at = excluded.created_at
            ''');
            for (final dynamic row in rows) {
              if (row is List<dynamic> && row.length >= 5) {
                stmt.execute(<Object?>[
                  row[0]?['value'],
                  row[1]?['value'],
                  row[2]?['value'] ?? '#000000',
                  _parseInteger(
                    row[4]?['value'],
                    DateTime.now().millisecondsSinceEpoch,
                  ),
                ]);
              }
            }
            stmt.dispose();
          }
        }
      }

      debugPrint('Turso pull completed.');
      return true;
    } catch (e) {
      // Type only. An exception thrown while decoding carries the offending
      // fragment of the response in its message, and that fragment is a row.
      _fail(_exceptionReason('pull', e));
      return false;
    }
  }

  /// A failed call, named by what it was and how it failed — never by what
  /// came back.
  ///
  /// `debugPrint` is not stripped from a release build, so anything handed to
  /// it lands in the OS log, outside everything this app can delete. A pipeline
  /// body is the user's captures; an exception message routinely quotes the
  /// input it choked on.
  void _fail(String reason) {
    _failureReason ??= reason;
    debugPrint(reason);
  }

  static String _statusReason(String phase, int statusCode) {
    final String action = phase == 'pull' ? 'read from' : 'write to';
    if (statusCode == 401 || statusCode == 403) {
      return 'Turso rejected the auth token while trying to $action the database (HTTP $statusCode).';
    }
    if (statusCode == 404) {
      return 'Turso database or pipeline endpoint was not found (HTTP 404). Check the database URL.';
    }
    if (statusCode == 408 || statusCode == 429) {
      return 'Turso temporarily refused the request (HTTP $statusCode). Try again later.';
    }
    if (statusCode >= 500) {
      return 'Turso is temporarily unavailable (HTTP $statusCode). Try again later.';
    }
    return 'Turso could not $action the database (HTTP $statusCode).';
  }

  static String _exceptionReason(String phase, Object error) {
    final String action = phase == 'pull' ? 'read from' : 'write to';
    if (error is TimeoutException) {
      return 'Turso request timed out while trying to $action the database.';
    }
    if (error is SocketException || error is HttpException) {
      return 'Could not reach Turso while trying to $action the database. Check your network and database URL.';
    }
    if (error is FormatException) {
      return 'Turso returned an invalid response while trying to $action the database.';
    }
    return 'Turso sync failed while trying to $action the database (${error.runtimeType}).';
  }

  Future<bool> pushToTurso({
    required String dbUrl,
    required String authToken,
  }) async {
    if (dbUrl.isEmpty || authToken.isEmpty || TokenCipher.isSealed(authToken)) {
      _fail('Turso credentials are missing or unavailable.');
      return false;
    }

    final String? endpoint = _getPipelineEndpoint(dbUrl);
    if (endpoint == null) {
      // The push is the half that uploads every capture, so an address that
      // cannot be trusted with the token cannot be trusted with the notes.
      _fail('Turso database URL must be an https:// or libsql:// address.');
      return false;
    }

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
              encodeArg(r['id']),
              encodeArg(r['file_path']),
              encodeArg(r['duration_ms'], integer: true),
              encodeArg(r['type']),
              encodeArg(r['status']),
              encodeArg(r['category']),
              encodeArg(r['title']),
              encodeArg(r['summary']),
              encodeArg(r['tags_json'] ?? '[]'),
              encodeArg(r['created_at'], integer: true),
              encodeArg(
                (r['is_processed_by_user'] == 1 ? 1 : 0),
                integer: true,
              ),
              encodeArg(r['project_id']),
              encodeArg(r['failure_reason']),
              encodeArg(r['json_payload']),
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
              encodeArg(c['id']),
              encodeArg(c['type']),
              encodeArg(c['text']),
              encodeArg(c['image_path']),
              encodeArg(c['copied_at'], integer: true),
              encodeArg(c['preview']),
              encodeArg(c['collections_json'] ?? '[]'),
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
              encodeArg(p['id']),
              encodeArg(p['name']),
              encodeArg(p['color_hex']),
              encodeArg(p['repository_path']),
              encodeArg(p['created_at'], integer: true),
            ],
          },
        });
      }

      if (requests.isEmpty) return true;

      final http.Response response = await _client
          .post(
            Uri.parse(endpoint),
            headers: <String, String>{
              'Authorization': 'Bearer $authToken',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(<String, dynamic>{'requests': requests}),
          )
          .timeout(_requestTimeout);

      if (response.statusCode != 200) {
        _fail(_statusReason('push', response.statusCode));
        return false;
      }
      return true;
    } catch (e) {
      _fail(_exceptionReason('push', e));
      return false;
    }
  }

  Future<bool> syncTwoWay({
    required String dbUrl,
    required String authToken,
  }) async {
    _failureReason = null;
    final bool pulled = await pullFromTurso(dbUrl: dbUrl, authToken: authToken);
    final bool pushed = await pushToTurso(dbUrl: dbUrl, authToken: authToken);
    return pulled && pushed;
  }
}
