import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import '../database/app_database.dart';

class R2RemoteObject {
  const R2RemoteObject({required this.sha256, required this.size});

  final String? sha256;
  final int size;
}

abstract interface class R2ObjectStore {
  Future<void> validate();

  Future<R2RemoteObject?> head(String key);

  Future<void> upload({
    required String key,
    required File source,
    required String sha256,
  });

  Future<void> download({required String key, required File destination});
}

class R2StoreException implements Exception {
  const R2StoreException(this.message);

  final String message;

  @override
  String toString() => message;
}

class R2ObjectAlreadyExistsException extends R2StoreException {
  const R2ObjectAlreadyExistsException()
    : super('R2 object was created by another sync.');
}

class R2SyncResult {
  const R2SyncResult({
    required this.success,
    this.uploaded = 0,
    this.downloaded = 0,
    this.unchanged = 0,
    this.conflicts = 0,
    this.missing = 0,
    this.failureReason,
  });

  final bool success;
  final int uploaded;
  final int downloaded;
  final int unchanged;
  final int conflicts;
  final int missing;
  final String? failureReason;
}

class R2MediaSyncService {
  const R2MediaSyncService({required this.db, required this.store});

  final AppDatabase db;
  final R2ObjectStore store;

  Future<R2SyncResult> sync() async {
    int uploaded = 0;
    int downloaded = 0;
    int unchanged = 0;
    int conflicts = 0;
    int missing = 0;

    try {
      await store.validate();
      for (final _MediaFile media in _mediaFiles()) {
        final File local = File(media.path);
        final R2RemoteObject? remote = await store.head(media.key);
        final bool localExists = await local.exists();

        if (localExists && remote == null) {
          final String localHash = await _hash(local);
          try {
            await store.upload(
              key: media.key,
              source: local,
              sha256: localHash,
            );
            uploaded++;
          } on R2ObjectAlreadyExistsException {
            final R2RemoteObject? raced = await store.head(media.key);
            if (raced?.sha256 == localHash) {
              unchanged++;
            } else {
              conflicts++;
            }
          }
          continue;
        }

        if (!localExists && remote == null) {
          missing++;
          continue;
        }

        if (localExists) {
          final String localHash = await _hash(local);
          if (remote!.sha256 == localHash) {
            unchanged++;
          } else {
            conflicts++;
          }
          continue;
        }

        final String? expectedHash = remote!.sha256;
        if (expectedHash == null) {
          conflicts++;
          continue;
        }

        await local.parent.create(recursive: true);
        final File partial = File('${local.path}.${const Uuid().v4()}.r2.part');
        try {
          await store.download(key: media.key, destination: partial);
          final String receivedHash = await _hash(partial);
          if (receivedHash != expectedHash) {
            conflicts++;
            continue;
          }
          await partial.rename(local.path);
          downloaded++;
        } finally {
          if (await partial.exists()) await partial.delete();
        }
      }
    } on R2StoreException catch (error) {
      return R2SyncResult(
        success: false,
        uploaded: uploaded,
        downloaded: downloaded,
        unchanged: unchanged,
        conflicts: conflicts,
        missing: missing,
        failureReason: error.message,
      );
    } on TimeoutException {
      return R2SyncResult(
        success: false,
        uploaded: uploaded,
        downloaded: downloaded,
        unchanged: unchanged,
        conflicts: conflicts,
        missing: missing,
        failureReason: 'R2 request timed out. Try again.',
      );
    } on SocketException {
      return R2SyncResult(
        success: false,
        uploaded: uploaded,
        downloaded: downloaded,
        unchanged: unchanged,
        conflicts: conflicts,
        missing: missing,
        failureReason: 'Could not reach R2. Check your network and endpoint.',
      );
    } catch (error) {
      return R2SyncResult(
        success: false,
        uploaded: uploaded,
        downloaded: downloaded,
        unchanged: unchanged,
        conflicts: conflicts,
        missing: missing,
        failureReason: 'R2 sync failed (${error.runtimeType}).',
      );
    }

    final bool success = conflicts == 0 && missing == 0;
    return R2SyncResult(
      success: success,
      uploaded: uploaded,
      downloaded: downloaded,
      unchanged: unchanged,
      conflicts: conflicts,
      missing: missing,
      failureReason: success
          ? null
          : <String>[
              if (conflicts > 0)
                '$conflicts conflict${conflicts == 1 ? '' : 's'}',
              if (missing > 0) '$missing missing',
            ].join(' · '),
    );
  }

  List<_MediaFile> _mediaFiles() {
    final Map<String, _MediaFile> files = <String, _MediaFile>{};
    final rows = db.rawDb.select(
      'SELECT id, file_path, json_payload FROM recordings',
    );
    for (final row in rows) {
      final String id = row['id'] as String;
      if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id)) continue;
      void add(Object? rawPath) {
        if (rawPath is! String || rawPath.trim().isEmpty) return;
        final String name = p.basename(rawPath);
        if (name.isEmpty || name == '.' || name == '..') return;
        final String key = 'captures/$id/$name';
        files[key] = _MediaFile(key: key, path: rawPath);
      }

      add(row['file_path']);
      final Object? rawPayload = row['json_payload'];
      if (rawPayload is String && rawPayload.isNotEmpty) {
        try {
          final Object? decoded = jsonDecode(rawPayload);
          if (decoded is Map<String, dynamic>) {
            final Object? segments = decoded['segments'];
            if (segments is List) {
              for (final Object? segment in segments) {
                if (segment is Map<String, dynamic>) add(segment['filePath']);
              }
            }
          }
        } on FormatException {
          // The primary source remains usable when a legacy payload is broken.
        }
      }
    }
    return files.values.toList();
  }

  static Future<String> _hash(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();
}

class _MediaFile {
  const _MediaFile({required this.key, required this.path});

  final String key;
  final String path;
}
