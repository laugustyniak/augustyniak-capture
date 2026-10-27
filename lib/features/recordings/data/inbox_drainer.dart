import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../logs/domain/log_event.dart';

/// Moves notes written by external producers (a Siri App Intent, the Android
/// CREATE_NOTE activity) from the inbox directory into the capture pipeline.
///
/// A producer writes `<uuid>.txt.tmp`, renames it to `<uuid>.txt` and only then
/// confirms to the user. A file is deleted only after [ingest] reports the note
/// persisted; every other outcome keeps it for the next drain. The uuid in the
/// name becomes the Recording id, so a crash between persist and delete just
/// makes the next drain a no-op for that file.
class InboxDrainer {
  InboxDrainer({
    required this.inbox,
    required this.ingest,
    this.ingestAudio,
    required LogSink logSink,
  }) : _logSink = logSink;

  final Directory inbox;
  final Future<bool> Function(String id, String body) ingest;

  /// Takes a finished `<uuid>.m4a` from the Android Auto car app. When null,
  /// `.m4a` files are ignored and stay in the inbox.
  final Future<bool> Function(String id, File file)? ingestAudio;
  final LogSink _logSink;

  static final RegExp _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false,
  );

  static const Duration _staleTmp = Duration(hours: 1);

  bool _draining = false;

  /// Returns how many notes were persisted. A call made while another drain is
  /// running returns 0 rather than racing it.
  Future<int> drain() async {
    if (_draining) return 0;
    _draining = true;
    try {
      return await _drain();
    } finally {
      _draining = false;
    }
  }

  Future<int> _drain() async {
    if (!await inbox.exists()) return 0;
    final List<(File, DateTime)> files = <(File, DateTime)>[];
    int partialAudio = 0;
    try {
      await for (final FileSystemEntity e in inbox.list()) {
        if (e is! File) continue;
        // Per entry: a producer renaming its .tmp between the listing and the
        // stat must cost that entry, not the whole pass.
        try {
          final String extension = p.extension(e.path);
          if (extension == '.txt' ||
              (extension == '.m4a' && ingestAudio != null)) {
            files.add((e, await e.lastModified()));
          } else if (e.path.endsWith('.m4a.tmp') &&
              DateTime.now().difference(await e.lastModified()) > _staleTmp) {
            // An interrupted car recording: never swept, it may be the only
            // copy of what the user said.
            partialAudio++;
          } else if (e.path.endsWith('.txt.tmp') &&
              DateTime.now().difference(await e.lastModified()) > _staleTmp) {
            // A producer that crashed mid-write; a live one renames within
            // milliseconds.
            await e.delete();
            _log('Inbox: removed stale partial write ${p.basename(e.path)}');
          }
        } on FileSystemException catch (exception) {
          _log('Inbox entry skipped: ${p.basename(e.path)} · $exception');
        }
      }
    } on FileSystemException catch (exception) {
      _log('Inbox unreadable: $exception');
      return 0;
    }
    if (partialAudio > 0) {
      _log(
        'Inbox: $partialAudio interrupted car recording(s) '
        '(*.m4a.tmp) kept for manual recovery',
      );
    }
    files.sort(
      ((File, DateTime) a, (File, DateTime) b) => a.$2.compareTo(b.$2),
    );

    int persisted = 0;
    for (final (File file, _) in files) {
      final String id = p.basenameWithoutExtension(file.path);
      if (!_uuid.hasMatch(id)) {
        _log(
          'Inbox file skipped, name is not a uuid: ${p.basename(file.path)}',
        );
        continue;
      }
      try {
        if (p.extension(file.path) == '.m4a') {
          if (await ingestAudio!(id, file)) {
            await file.delete();
            persisted++;
          }
          continue;
        }
        final String body = utf8.decode(await file.readAsBytes());
        if (body.trim().isEmpty) {
          await file.delete();
          _log('Inbox note was empty, deleted: $id');
          continue;
        }
        if (await ingest(id, body)) {
          await file.delete();
          persisted++;
        }
      } catch (exception) {
        _log('Inbox note not ingested, kept: $id · $exception');
      }
    }
    return persisted;
  }

  void _log(String message) {
    try {
      _logSink.log(message, level: LogLevel.warn);
    } catch (_) {
      // Best-effort sink: never fail a drain.
    }
  }
}
