import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../domain/whisper_model.dart';

/// How far a download has got.
class ModelDownloadProgress {
  const ModelDownloadProgress({required this.received, required this.total});

  final int received;

  /// What the server promised, or null when it promised nothing — a chunked
  /// response has no length, and reporting a fabricated denominator would draw
  /// a progress bar that lies rather than one that is honestly indeterminate.
  final int? total;

  double? get fraction {
    final int? bound = total;
    if (bound == null || bound <= 0) return null;
    return (received / bound).clamp(0, 1).toDouble();
  }
}

/// An installed model, and whether its bytes were checked against a pin.
class InstalledModel {
  const InstalledModel({
    required this.id,
    required this.path,
    required this.bytes,
    required this.verified,
  });

  final String id;
  final String path;
  final int bytes;

  /// False when the catalog carries no pinned hash for this model. Surfaced
  /// rather than assumed: "checked and correct" and "nothing to check against"
  /// are different claims, and only the first is worth making.
  final bool verified;
}

/// Downloads, verifies, lists and deletes on-device models.
///
/// **Models live in Application Support, never in the documents directory.**
/// `recoverOrphans()` scans the recordings directory and re-adopts anything
/// there that is not an index or a poster — a half-gigabyte model beside the
/// sources would be walked back into the queue as a capture on the next launch.
class WhisperModelStore {
  WhisperModelStore({
    Future<Directory> Function()? directoryProvider,
    http.Client? client,
  }) : _directoryProvider = directoryProvider ?? _defaultDirectory,
       _client = client ?? http.Client();

  /// The same seam `RecordingsRepository` and `ProjectsRepository` carry, and
  /// for the same reason: it is the one `path_provider` touchpoint, so
  /// overriding it lets the whole download-verify-rename pipeline run against a
  /// temp directory with no platform binding.
  final Future<Directory> Function() _directoryProvider;
  final http.Client _client;

  static const String directoryName = 'speech-models';

  /// The suffix a download carries until it has been checked.
  ///
  /// A partial file must never be reachable by [pathFor]: a truncated model
  /// does not fail loudly, it produces worse text — which is the quietest
  /// failure this feature could have.
  static const String partialSuffix = '.part';

  static Future<Directory> _defaultDirectory() async {
    final Directory support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, directoryName));
  }

  Future<Directory> _directory() async {
    final Directory directory = await _directoryProvider();
    if (!await directory.exists()) await directory.create(recursive: true);
    return directory;
  }

  /// Where [id] would live. Says nothing about whether it is there.
  Future<String> plannedPath(String id) async {
    final WhisperModel? model = WhisperModelCatalog.byId(id);
    final Directory directory = await _directory();
    return p.join(directory.path, model?.fileName ?? 'ggml-$id.bin');
  }

  /// The path of an installed model, or null.
  ///
  /// **Answered from disk every time, never from a remembered list.** A user
  /// who deletes the file by hand — or a phone that evicts it — must stop being
  /// offered a model that is not there, and a cache would keep offering it
  /// until the app was restarted.
  Future<String?> pathFor(String id) async {
    final String path = await plannedPath(id);
    return await File(path).exists() ? path : null;
  }

  Future<List<InstalledModel>> installed() async {
    final List<InstalledModel> found = <InstalledModel>[];
    for (final WhisperModel model in WhisperModelCatalog.all) {
      final String? path = await pathFor(model.id);
      if (path == null) continue;
      found.add(
        InstalledModel(
          id: model.id,
          path: path,
          bytes: await File(path).length(),
          verified: model.sha256 != null,
        ),
      );
    }
    return found;
  }

  /// Removes [id], and any partial download left behind for it.
  ///
  /// Returns false when there was nothing to remove, so a caller can tell "it
  /// is gone now" from "it was never there" — the same distinction the restore
  /// report draws between added and already present.
  Future<bool> delete(String id) async {
    final String path = await plannedPath(id);
    final File file = File(path);
    final File partial = File('$path$partialSuffix');
    bool removed = false;
    if (await file.exists()) {
      await file.delete();
      removed = true;
    }
    if (await partial.exists()) {
      await partial.delete();
      removed = true;
    }
    return removed;
  }

  /// Fetches [model], verifies it, and installs it.
  ///
  /// Streamed to `<name>.part` and renamed only once it is whole, which is the
  /// atomic discipline every index in this app already uses — with a stronger
  /// reason here, because a torn model is not unreadable, it is merely worse,
  /// and nothing downstream would ever say so.
  ///
  /// [cancelledBy] aborts the transfer when it completes. A download of this
  /// size has to be interruptible: on a phone it is the difference between a
  /// mistake and a metered gigabyte.
  Future<InstalledModel> download(
    WhisperModel model, {
    void Function(ModelDownloadProgress progress)? onProgress,
    Future<void>? cancelledBy,
  }) async {
    final String path = await plannedPath(model.id);
    final File destination = File(path);
    if (await destination.exists()) {
      return InstalledModel(
        id: model.id,
        path: path,
        bytes: await destination.length(),
        verified: model.sha256 != null,
      );
    }

    final File partial = File('$path$partialSuffix');
    if (await partial.exists()) await partial.delete();

    final http.StreamedResponse response = await _client.send(
      http.Request('GET', model.url),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ModelDownloadException(
        model.id,
        'the server answered ${response.statusCode}',
      );
    }

    final int? total = response.contentLength;
    int received = 0;
    // Accumulated while the bytes stream past rather than by re-reading the
    // finished file: a second full read of half a gigabyte to check something
    // already in hand is a cost with nothing to show for it.
    final _DigestCollector collector = _DigestCollector();
    final ByteConversionSink digestSink = sha256.startChunkedConversion(
      collector,
    );
    final IOSink sink = partial.openWrite();
    bool cancelled = false;
    bool closed = false;
    unawaited(cancelledBy?.then((_) => cancelled = true));

    Future<void> closeSink() async {
      if (closed) return;
      closed = true;
      await sink.close();
    }

    Future<void> discard() async {
      await closeSink();
      if (await partial.exists()) await partial.delete();
    }

    // **Every way out of the transfer discards the partial, including the ones
    // that throw from inside the loop.** Cancellation does exactly that, and
    // with the cleanup sitting after the `try` it never ran — leaving a
    // half-written file under the name a later download checks for. A partial
    // that survives is the one thing this class must not produce: it is not
    // distinguishable from an install by anything downstream.
    try {
      await for (final List<int> chunk in response.stream) {
        if (cancelled) throw const ModelDownloadCancelled();
        sink.add(chunk);
        digestSink.add(chunk);
        received += chunk.length;
        onProgress?.call(
          ModelDownloadProgress(received: received, total: total),
        );
      }
      await sink.flush();
      await closeSink();
    } catch (_) {
      await discard();
      rethrow;
    }

    // The truncation check that needs no catalog data and cannot go stale: what
    // arrived against what the server itself promised.
    if (total != null && received != total) {
      await discard();
      throw ModelDownloadException(
        model.id,
        'the download stopped early — $received of $total bytes arrived',
      );
    }

    digestSink.close();
    final String? pinned = model.sha256;
    if (pinned != null) {
      final String actual = collector.value.toString();
      if (actual.toLowerCase() != pinned.toLowerCase()) {
        await discard();
        throw ModelDownloadException(
          model.id,
          'the downloaded bytes do not match the published checksum',
        );
      }
    }

    await partial.rename(path);
    return InstalledModel(
      id: model.id,
      path: path,
      bytes: received,
      verified: pinned != null,
    );
  }
}

/// Collects the streamed digest. A sink rather than a return value because
/// `crypto`'s chunked conversion hands its result to one — and an instance
/// rather than a static, so two concurrent downloads cannot read each other's.
class _DigestCollector implements Sink<Digest> {
  Digest? _value;

  Digest get value => _value!;

  @override
  void add(Digest data) => _value = data;

  @override
  void close() {}
}

class ModelDownloadException implements Exception {
  const ModelDownloadException(this.modelId, this.reason);

  final String modelId;
  final String reason;

  @override
  String toString() => 'Could not install "$modelId": $reason.';
}

class ModelDownloadCancelled implements Exception {
  const ModelDownloadCancelled();

  @override
  String toString() => 'The download was cancelled.';
}
