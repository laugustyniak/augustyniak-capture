import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../../core/sync/sync_path_policy.dart';
import '../../recordings/domain/capture_segment.dart';
import '../../recordings/domain/recording.dart';

/// Private object storage for capture media, keyed relative to the signed-in
/// user — the store adds the owner prefix its access policy checks, so this
/// side never names a user.
abstract interface class MediaObjectStore {
  Future<bool> exists(String key);

  /// Never overwrites: an object already under [key] throws
  /// [MediaObjectExistsException].
  Future<void> upload(String key, File source, {required String sha256});

  Future<List<int>> download(String key);
}

/// The seam's default: wiring never fails, use does.
class DisabledMediaObjectStore implements MediaObjectStore {
  const DisabledMediaObjectStore();

  Never _unavailable() => throw StateError('Media sync is not configured');

  @override
  Future<bool> exists(String key) async => _unavailable();

  @override
  Future<void> upload(
    String key,
    File source, {
    required String sha256,
  }) async => _unavailable();

  @override
  Future<List<int>> download(String key) async => _unavailable();
}

class MediaObjectExistsException implements Exception {
  const MediaObjectExistsException();
}

class MediaSyncResult {
  const MediaSyncResult({
    this.uploaded = 0,
    this.downloaded = 0,
    this.unchanged = 0,
    this.waiting = 0,
    this.unverifiable = 0,
    this.rejected = 0,
    this.failureReason,
  });

  final int uploaded;
  final int downloaded;
  final int unchanged;

  /// Pulled rows whose media the capturing device has not uploaded yet — the
  /// normal state while that device is offline, so not a failure.
  final int waiting;

  /// Pulled segments with no `contentHash` to check a download against.
  /// Never downloaded: an unverified file must not land as a source.
  final int unverifiable;

  /// Downloads whose bytes did not match the synced `contentHash`. Nothing
  /// is written for them.
  final int rejected;
  final String? failureReason;

  bool get success => failureReason == null && rejected == 0;
}

/// One segment source: where it lives on this device and what its bytes
/// must hash to.
class MediaSyncJob {
  const MediaSyncJob({
    required this.key,
    required this.localPath,
    required this.contentHash,
  });

  final String key;
  final String localPath;
  final String? contentHash;

  /// Every segment of every recording whose id and file name are safe to put
  /// in an object key. Paths must already be absolute — see
  /// `RecordingsController`'s re-root step, which runs first.
  static List<MediaSyncJob> forRecordings(Iterable<Recording> recordings) {
    final Map<String, MediaSyncJob> jobs = <String, MediaSyncJob>{};
    for (final Recording r in recordings) {
      if (!_safeId.hasMatch(r.id)) continue;
      for (final CaptureSegment segment in r.segments) {
        final String? name = SyncPathPolicy.localFileName(segment.filePath);
        if (name == null || !p.isAbsolute(segment.filePath)) continue;
        final String key = 'captures/${r.id}/$name';
        jobs[key] = MediaSyncJob(
          key: key,
          localPath: segment.filePath,
          contentHash: segment.contentHash,
        );
      }
    }
    return jobs.values.toList();
  }

  static final RegExp _safeId = RegExp(r'^[A-Za-z0-9_-]+$');
}

/// Uploads local sources the store lacks and downloads pulled sources this
/// device lacks. A download lands only after its bytes are non-empty and
/// hash to the synced `contentHash` — written to a `.part` beside the
/// target, then renamed, so a torn or wrong transfer never becomes a source.
/// It never touches a recording's row or status.
class MediaSyncService {
  const MediaSyncService({required this.store});

  final MediaObjectStore store;

  Future<MediaSyncResult> sync(List<MediaSyncJob> jobs) async {
    int uploaded = 0;
    int downloaded = 0;
    int unchanged = 0;
    int waiting = 0;
    int unverifiable = 0;
    int rejected = 0;

    MediaSyncResult result([String? failureReason]) => MediaSyncResult(
      uploaded: uploaded,
      downloaded: downloaded,
      unchanged: unchanged,
      waiting: waiting,
      unverifiable: unverifiable,
      rejected: rejected,
      failureReason: failureReason,
    );

    try {
      for (final MediaSyncJob job in jobs) {
        final File local = File(job.localPath);
        if (await local.exists() && await local.length() > 0) {
          if (await store.exists(job.key)) {
            unchanged++;
            continue;
          }
          try {
            await store.upload(job.key, local, sha256: await _hash(local));
            uploaded++;
          } on MediaObjectExistsException {
            unchanged++;
          }
          continue;
        }

        final String? expected = job.contentHash;
        if (expected == null) {
          unverifiable++;
          continue;
        }
        if (!await store.exists(job.key)) {
          waiting++;
          continue;
        }
        final List<int> bytes = await store.download(job.key);
        if (bytes.isEmpty || sha256.convert(bytes).toString() != expected) {
          rejected++;
          continue;
        }
        await local.parent.create(recursive: true);
        final File partial = File('${local.path}.${const Uuid().v4()}.part');
        try {
          await partial.writeAsBytes(bytes, flush: true);
          await partial.rename(local.path);
          downloaded++;
        } finally {
          if (await partial.exists()) await partial.delete();
        }
      }
    } on TimeoutException {
      return result('Storage request timed out. Try again.');
    } on SocketException {
      return result('Could not reach Storage. Check your network.');
    } catch (error) {
      return result('Storage sync failed (${error.runtimeType}).');
    }
    return result(
      rejected > 0
          ? '$rejected download${rejected == 1 ? '' : 's'} failed verification'
          : null,
    );
  }

  static Future<String> _hash(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();
}
