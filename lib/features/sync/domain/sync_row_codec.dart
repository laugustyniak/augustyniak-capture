import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../clipboard/domain/clipboard_item.dart';
import '../../projects/domain/project.dart';
import '../../recordings/domain/recording.dart';
import '../../recordings/domain/recording_revision.dart';
import 'sync_table.dart';

/// Canonical server-row shape for each synced type, and the hash the engine
/// compares against `sync_rows.pushed_hash`.
///
/// A row never carries `owner_id` or `updated_at`: the server owns both. The
/// hash excludes `version` and `deleted_at` — bookkeeping, not content — so a
/// row's identity is what the user would recognise as the same capture.
class SyncRowCodec {
  SyncRowCodec._();

  static String _utc(DateTime at) => at.toUtc().toIso8601String();
  static DateTime? _date(Object? raw) =>
      raw is String ? DateTime.tryParse(raw)?.toUtc() : null;

  /// Sorts only the top level. Every nested value (`tags`, `payload`,
  /// `collections`) is produced deterministically by this codec itself — the
  /// same Dart list/map, built the same way, every call — so a recursive sort
  /// would not change the JSON text it produces. A hand-built row that
  /// nested its keys out of order would need one, but nothing in this class
  /// builds rows that way.
  ///
  /// This assumes `hash()` only ever compares codec output to codec output
  /// (push-time content hashing). Postgres `jsonb` canonicalizes key order on
  /// storage, so a `payload` read back from the server has its nested keys in
  /// a different order than what was pushed; hashing a *pulled* row against
  /// `pushed_hash` would need the recursive sort this method deliberately
  /// skips.
  static String hash(Map<String, Object?> row) {
    final List<MapEntry<String, Object?>> entries = row.entries
        .where(
          (MapEntry<String, Object?> e) =>
              e.key != 'version' &&
              e.key != 'deleted_at' &&
              e.key != 'owner_id' &&
              e.key != 'updated_at',
        )
        .toList()
      ..sort(
        (MapEntry<String, Object?> a, MapEntry<String, Object?> b) =>
            a.key.compareTo(b.key),
      );
    final Map<String, Object?> canonical = Map<String, Object?>.fromEntries(
      entries,
    );
    return sha256.convert(utf8.encode(jsonEncode(canonical))).toString();
  }

  static String rowId(SyncTable table, Map<String, Object?> row) =>
      table.keyColumns.map((String c) => '${row[c]}').join('/');

  // ---- recordings ---------------------------------------------------------

  static Map<String, Object?> recording(Recording r) {
    final Map<String, dynamic> json = r.toJson();
    // Everything with no column of its own rides in `payload`, so a round
    // trip through the server loses nothing — except the device-specific
    // absolute paths nested inside it, which are basenamed exactly like the
    // top-level `file_path` column. Nothing device-specific leaves the
    // device, `payload` included.
    final Map<String, Object?> payload = <String, Object?>{
      'thumbPath': json['thumbPath'] is String
          ? p.basename(json['thumbPath'] as String)
          : json['thumbPath'],
      'routes': json['routes'],
      'artifacts': json['artifacts'],
      if (json.containsKey('segments'))
        'segments': _basenameSegmentPaths(json['segments']),
    };
    return <String, Object?>{
      'id': r.id,
      'file_path': p.basename(r.filePath),
      'duration_ms': r.durationMs,
      'size_bytes': r.sizeBytes,
      'content_hash': r.contentHash,
      'type': r.type.name,
      'status': r.status.name,
      'source_mime_type': r.sourceMimeType,
      'transcript': r.transcript,
      'category': r.category?.name,
      'title': r.title,
      'summary': r.summary,
      'tags': r.tags,
      'created_at': _utc(r.createdAt),
      'is_processed_by_user': r.isProcessedByUser,
      'processed_at': r.processedAt == null ? null : _utc(r.processedAt!),
      'project_id': r.projectId,
      'failure_reason': r.error,
      'payload': payload,
    };
  }

  /// `filePath` only — every other segment field is left as the processor
  /// wrote it.
  static Object? _basenameSegmentPaths(Object? raw) {
    if (raw is! List) return raw;
    return <Map<String, dynamic>>[
      for (final dynamic segment in raw)
        if (segment is Map<String, dynamic>)
          <String, dynamic>{
            ...segment,
            if (segment['filePath'] is String)
              'filePath': p.basename(segment['filePath'] as String),
          },
    ];
  }

  static Recording? recordingFromRow(
    Map<String, Object?> row, {
    Recording? local,
  }) {
    final Object? id = row['id'];
    final DateTime? createdAt = _date(row['created_at']);
    if (id is! String || createdAt == null) return null;
    final Object? payloadRaw = row['payload'];
    final Map<String, dynamic> payload = payloadRaw is Map
        ? Map<String, dynamic>.from(payloadRaw)
        : <String, dynamic>{};
    final String fileName = row['file_path'] is String
        ? row['file_path'] as String
        : '';
    // Restore this device's own absolute paths when they are known; a fresh
    // install (no `local`) keeps the bare names payload/file_path carry, and
    // a later slice resolves them against the recordings directory.
    final Map<int, String> localSegmentPaths = <int, String>{
      if (local != null)
        for (final segment in local.segments) segment.index: segment.filePath,
    };
    final Map<String, dynamic> json = <String, dynamic>{
      'id': id,
      'filePath': local?.filePath ?? fileName,
      'createdAt': createdAt.toIso8601String(),
      'durationMs': row['duration_ms'] is int ? row['duration_ms'] : 0,
      'sizeBytes': row['size_bytes'] is int ? row['size_bytes'] : 0,
      'contentHash': row['content_hash'],
      'status': row['status'],
      'type': row['type'],
      'sourceMimeType': row['source_mime_type'],
      'transcript': row['transcript'],
      'thumbPath': local?.thumbPath ?? payload['thumbPath'],
      'title': row['title'],
      'category': row['category'],
      'summary': row['summary'],
      'tags': row['tags'] is List ? row['tags'] : <String>[],
      'projectId': row['project_id'],
      'error': row['failure_reason'],
      'isProcessedByUser': row['is_processed_by_user'] == true,
      'processedAt': row['processed_at'],
      'routes': payload['routes'] ?? <Object?>[],
      'artifacts': payload['artifacts'] ?? <Object?>[],
      if (payload.containsKey('segments'))
        'segments': _restoreSegmentPaths(payload['segments'], localSegmentPaths)
      else if (local != null && local.hasStoredSegments)
        'segments': local.toJson()['segments'],
    };
    try {
      return Recording.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  /// Restores each segment's `filePath` from the local segment sharing its
  /// `index`, when one exists; otherwise the bare name from `payload` stays.
  static Object? _restoreSegmentPaths(
    Object? payloadSegments,
    Map<int, String> localPathsByIndex,
  ) {
    if (payloadSegments is! List) return payloadSegments;
    return <Map<String, dynamic>>[
      for (final dynamic segment in payloadSegments)
        if (segment is Map<String, dynamic>)
          <String, dynamic>{
            ...segment,
            if (segment['index'] is int &&
                localPathsByIndex.containsKey(segment['index'] as int))
              'filePath': localPathsByIndex[segment['index'] as int],
          },
    ];
  }

  static List<Map<String, Object?>> segments(Recording r) {
    final Object? raw = r.toJson()['segments'];
    if (raw is! List) return const <Map<String, Object?>>[];
    return <Map<String, Object?>>[
      for (final Object? item in raw)
        if (item is Map)
          <String, Object?>{
            'recording_id': r.id,
            'index': item['index'],
            'file_path': p.basename(item['filePath'] as String? ?? ''),
            'type': item['type'],
            'source_mime_type': item['sourceMimeType'],
            'created_at': switch (_date(item['createdAt'])) {
              final DateTime at => _utc(at),
              null => null,
            },
            'duration_ms': item['durationMs'],
            'size_bytes': item['sizeBytes'],
            'content_hash': item['contentHash'],
            'text': item['text'],
            'error': item['error'],
          },
    ];
  }

  // ---- projects -----------------------------------------------------------

  static Map<String, Object?> project(Project pr) => <String, Object?>{
    'id': pr.id,
    'name': pr.name,
    'repository_path': pr.repoPath,
    'payload': pr.toJson()
      ..remove('id')
      ..remove('name')
      ..remove('repoPath'),
  };

  static Project? projectFromRow(Map<String, Object?> row) {
    if (row['id'] is! String) return null;
    final Object? payloadRaw = row['payload'];
    final Map<String, dynamic> json = <String, dynamic>{
      if (payloadRaw is Map) ...Map<String, dynamic>.from(payloadRaw),
      'id': row['id'],
      'name': row['name'],
      'repoPath': row['repository_path'] ?? '',
    };
    try {
      return Project.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  // ---- clipboard ----------------------------------------------------------

  static Map<String, Object?> clipboardItem(ClipboardItem c) =>
      <String, Object?>{
        'id': c.id,
        'type': c.type.name,
        'text': c.text,
        'image_path': c.imagePath == null ? null : p.basename(c.imagePath!),
        'copied_at': _utc(c.copiedAt),
        'preview': c.preview,
        'collections': c.collections.toList()..sort(),
      };

  static ClipboardItem? clipboardItemFromRow(Map<String, Object?> row) {
    final DateTime? copiedAt = _date(row['copied_at']);
    if (row['id'] is! String || copiedAt == null) return null;
    try {
      return ClipboardItem.fromJson(<String, dynamic>{
        'id': row['id'],
        'type': row['type'],
        'copiedAt': copiedAt.toIso8601String(),
        if (row['text'] != null) 'text': row['text'],
        if (row['image_path'] != null) 'imagePath': row['image_path'],
        if (row['preview'] != null) 'preview': row['preview'],
        if (row['collections'] is List) 'collections': row['collections'],
      });
    } catch (_) {
      return null;
    }
  }

  // ---- revisions ----------------------------------------------------------

  static Map<String, Object?> revision(RecordingRevision r) =>
      <String, Object?>{
        'recording_id': r.recordingId,
        'at': _utc(r.at),
        'field': r.field,
        'from_value': r.from,
        'to_value': r.to,
        'source': r.source.name,
      };

  /// Degrades to null on a row missing a required field, rather than
  /// throwing — the project-wide `fromJson` rule.
  static RecordingRevision? revisionFromRow(Map<String, Object?> row) {
    final Object? recordingId = row['recording_id'];
    final Object? field = row['field'];
    final DateTime? at = _date(row['at']);
    if (recordingId is! String || field is! String || at == null) {
      return null;
    }
    final Object? fromValue = row['from_value'];
    final Object? toValue = row['to_value'];
    return RecordingRevision(
      recordingId: recordingId,
      at: at,
      field: field,
      from: fromValue is String ? fromValue : null,
      to: toValue is String ? toValue : null,
      source: RevisionSource.fromName(
        row['source'] is String ? row['source'] as String : null,
      ),
    );
  }

  // ---- devices ------------------------------------------------------------

  static Map<String, Object?> device({
    required String id,
    required String name,
    required String platform,
    String? appVersion,
  }) => <String, Object?>{
    'id': id,
    'name': name,
    'platform': platform,
    'app_version': appVersion,
  };
}
