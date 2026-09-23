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
    this.failed = 0,
    this.failureReason,
  });

  final int uploaded;
  final int downloaded;
  final int unchanged;

  /// Sources not ready to transfer, neither a failure: a pulled row whose
  /// media the capturing device has not uploaded yet, or a local source that
  /// does not hash to its row's `contentHash` yet (a take still being
  /// finalised, or one never hashed). The bucket is write-once, so uploading
  /// such a file would pin the wrong bytes for every other device.
  final int waiting;

  /// Pulled segments with no `contentHash` to check a download against.
  /// Never downloaded: an unverified file must not land as a source.
  final int unverifiable;

  /// Downloads whose bytes did not match the synced `contentHash`. Nothing
  /// is written for them.
  final int rejected;

  /// Transfers that threw. Each is counted and the pass moves on, so one
  /// object the server refuses never holds back every older capture.
  final int failed;
  final String? failureReason;

  bool get success => failureReason == null && rejected == 0 && failed == 0;
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
  const MediaSyncService({required this.store, this.stillWanted});

  final MediaObjectStore store;

  /// Asked right before a verified download is renamed into place. A capture
  /// deleted while its download was in flight must not come back as an
  /// orphan the next launch re-adopts.
  final bool Function(MediaSyncJob job)? stillWanted;

  Future<MediaSyncResult> sync(List<MediaSyncJob> jobs) async {
    int uploaded = 0;
    int downloaded = 0;
    int unchanged = 0;
    int waiting = 0;
    int unverifiable = 0;
    int rejected = 0;
    int failed = 0;
    Object? lastError;

    MediaSyncResult result([String? failureReason]) => MediaSyncResult(
      uploaded: uploaded,
      downloaded: downloaded,
      unchanged: unchanged,
      waiting: waiting,
      unverifiable: unverifiable,
      rejected: rejected,
      failed: failed,
      failureReason: failureReason,
    );

    try {
      for (final MediaSyncJob job in jobs) {
        try {
          switch (await _transfer(job)) {
            case _Outcome.uploaded:
              uploaded++;
            case _Outcome.downloaded:
              downloaded++;
            case _Outcome.unchanged:
              unchanged++;
            case _Outcome.waiting:
              waiting++;
            case _Outcome.unverifiable:
              unverifiable++;
            case _Outcome.rejected:
              rejected++;
          }
        } on TimeoutException {
          rethrow;
        } on SocketException {
          rethrow;
        } catch (error) {
          failed++;
          lastError = error;
        }
      }
    } on TimeoutException {
      return result('Storage request timed out. Try again.');
    } on SocketException {
      return result('Could not reach Storage. Check your network.');
    }
    return result(
      <String>[
        if (rejected > 0)
          '$rejected download${rejected == 1 ? '' : 's'} failed verification',
        if (failed > 0)
          '$failed transfer${failed == 1 ? '' : 's'} failed '
              '(${lastError.runtimeType})',
      ].join(' · ').nullIfEmpty,
    );
  }

  Future<_Outcome> _transfer(MediaSyncJob job) async {
    final File local = File(job.localPath);
    final String? expected = job.contentHash;
    if (await local.exists() && await local.length() > 0) {
      if (await store.exists(job.key)) return _Outcome.unchanged;
      final String hash = await _hash(local);
      if (hash != expected) return _Outcome.waiting;
      try {
        await store.upload(job.key, local, sha256: hash);
        return _Outcome.uploaded;
      } on MediaObjectExistsException {
        return _Outcome.unchanged;
      }
    }

    if (expected == null) return _Outcome.unverifiable;
    if (!await store.exists(job.key)) return _Outcome.waiting;
    final List<int> bytes = await store.download(job.key);
    if (bytes.isEmpty || sha256.convert(bytes).toString() != expected) {
      return _Outcome.rejected;
    }
    await local.parent.create(recursive: true);
    final File partial = File('${local.path}.${const Uuid().v4()}.part');
    try {
      await partial.writeAsBytes(bytes, flush: true);
      if (stillWanted?.call(job) == false) return _Outcome.unchanged;
      await partial.rename(local.path);
      return _Outcome.downloaded;
    } finally {
      if (await partial.exists()) await partial.delete();
    }
  }

  static Future<String> _hash(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();
}

enum _Outcome {
  uploaded,
  downloaded,
  unchanged,
  waiting,
  unverifiable,
  rejected,
}

extension on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}
