import 'dart:async';
import 'dart:convert';
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

  /// Yields the object's bytes as they arrive and never more than [maxBytes]
  /// in total: an object past the ceiling errors with
  /// [MediaObjectTooLargeException] and is not read further.
  Stream<List<int>> download(String key, {required int maxBytes});
}

/// A download crossed the ceiling it was given.
class MediaObjectTooLargeException implements Exception {
  const MediaObjectTooLargeException(this.maxBytes);

  final int maxBytes;

  @override
  String toString() => 'Media object exceeded the $maxBytes byte ceiling.';
}

/// Forwards [source] until the running total would cross [maxBytes], then
/// errors with [MediaObjectTooLargeException] and stops pulling.
Stream<List<int>> boundedObjectBytes(
  Stream<List<int>> source, {
  required int maxBytes,
}) async* {
  int received = 0;
  await for (final List<int> chunk in source) {
    received += chunk.length;
    if (received > maxBytes) throw MediaObjectTooLargeException(maxBytes);
    yield chunk;
  }
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
  Stream<List<int>> download(String key, {required int maxBytes}) =>
      Stream<List<int>>.error(StateError('Media sync is not configured'));
}

class MediaObjectExistsException implements Exception {
  const MediaObjectExistsException();
}

/// The store could not be reached at all — every job after this one would
/// wait out the same failure, so it ends the pass rather than counting.
class MediaStoreUnreachableException implements Exception {
  const MediaStoreUnreachableException();
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

  /// Pulled segments with no `contentHash` to check a download against, or
  /// whose path lies outside the download root (a row an older build
  /// persisted before paths were reduced to names). Never downloaded.
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
    this.sizeBytes = 0,
  });

  final String key;
  final String localPath;
  final String? contentHash;

  /// What the row says the object weighs; 0 when an older build synced it
  /// without. A download is refused once it crosses this.
  final int sizeBytes;

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
          sizeBytes: segment.sizeBytes,
        );
      }
    }
    return jobs.values.toList();
  }

  static final RegExp _safeId = RegExp(r'^[A-Za-z0-9_-]+$');
}

/// Uploads local sources the store lacks and downloads pulled sources this
/// device lacks. A download is streamed to a `.part` beside the target and
/// hashed as it arrives, refused as soon as it crosses the row's `sizeBytes`;
/// it lands only after its bytes are non-empty and hash to the synced
/// `contentHash`, then renamed, so a torn or wrong transfer never becomes a
/// source.
/// It never touches a recording's row or status.
class MediaSyncService {
  const MediaSyncService({required this.store, this.stillWanted});

  final MediaObjectStore store;

  /// The ceiling for a row an older build synced without `size_bytes`.
  static const int fallbackDownloadCeilingBytes = 2 << 30;

  /// Asked right before a verified download is renamed into place. A capture
  /// deleted while its download was in flight must not come back as an
  /// orphan the next launch re-adopts.
  final bool Function(MediaSyncJob job)? stillWanted;

  /// [downloadRoot] is the only directory a download may land in. A row an
  /// older build persisted with a path outside it is uploaded from, never
  /// written to.
  Future<MediaSyncResult> sync(
    List<MediaSyncJob> jobs, {
    required String downloadRoot,
  }) async {
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
          switch (await _transfer(job, downloadRoot)) {
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
        } on MediaStoreUnreachableException {
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
    } on MediaStoreUnreachableException {
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

  Future<_Outcome> _transfer(MediaSyncJob job, String downloadRoot) async {
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

    if (expected == null || !p.isWithin(downloadRoot, local.path)) {
      return _Outcome.unverifiable;
    }
    if (!await store.exists(job.key)) return _Outcome.waiting;
    final int ceiling = job.sizeBytes > 0
        ? job.sizeBytes
        : fallbackDownloadCeilingBytes;
    await local.parent.create(recursive: true);
    final File partial = File('${local.path}.${const Uuid().v4()}.part');
    try {
      final _DigestCollector collector = _DigestCollector();
      final ByteConversionSink hashInput = sha256.startChunkedConversion(
        collector,
      );
      final IOSink out = partial.openWrite();
      int received = 0;
      try {
        await for (final List<int> chunk in store.download(
          job.key,
          maxBytes: ceiling,
        )) {
          received += chunk.length;
          hashInput.add(chunk);
          out.add(chunk);
        }
      } on MediaObjectTooLargeException {
        return _Outcome.rejected;
      } finally {
        // Flushed and closed on the error path too, so the .part can be removed.
        await out.close();
      }
      hashInput.close();
      if (received == 0 || collector.value.toString() != expected) {
        return _Outcome.rejected;
      }
      if (stillWanted?.call(job) == false) return _Outcome.unchanged;
      await partial.rename(local.path);
      // Asked again: a delete that started while the rename was in flight
      // could not see this file yet, and nothing would ever claim it.
      if (stillWanted?.call(job) == false) {
        // The delete may already have removed it.
        if (await local.exists()) await local.delete();
        return _Outcome.unchanged;
      }
      return _Outcome.downloaded;
    } finally {
      if (await partial.exists()) await partial.delete();
    }
  }

  static Future<String> _hash(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();
}

class _DigestCollector implements Sink<Digest> {
  Digest? _value;

  Digest get value => _value!;

  @override
  void add(Digest data) => _value = data;

  @override
  void close() {}
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
