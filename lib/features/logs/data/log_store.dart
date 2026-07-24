import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../domain/log_event.dart';

/// Where a `LogStore` reads and writes its ring buffer. Split out so the store
/// itself is a pure-Dart unit testable without platform channels.
abstract interface class LogArchive {
  Future<List<LogEvent>> load();
  Future<void> save(List<LogEvent> events);
}

/// Append-only event log, newest first, capped at [capacity].
///
/// Read-only from the UI's perspective: nothing here mutates recordings. Writes
/// to the archive are coalesced — `log()` returns immediately after updating
/// memory, and overlapping appends collapse into a single flush.
class LogStore extends ChangeNotifier implements LogSink {
  LogStore({LogArchive? archive, this.capacity = 500}) : _archive = archive;

  final LogArchive? _archive;
  final int capacity;
  final Uuid _uuid = const Uuid();

  List<LogEvent> _events = <LogEvent>[];
  bool _isFlushing = false;
  bool _isDirty = false;

  /// Newest first.
  List<LogEvent> get events => List<LogEvent>.unmodifiable(_events);

  List<LogEvent> eventsAtLevel(LogLevel? level) {
    if (level == null) return events;
    return List<LogEvent>.unmodifiable(
      _events.where((LogEvent event) => event.level == level),
    );
  }

  int countAtLevel(LogLevel level) =>
      _events.where((LogEvent event) => event.level == level).length;

  Future<void> initialize() async {
    final LogArchive? archive = _archive;
    if (archive == null) return;
    final List<LogEvent> loaded = await archive.load();
    _events = _capped(loaded);
    notifyListeners();
  }

  @override
  void log(String message, {LogLevel level = LogLevel.info, String? recordingId}) {
    add(
      LogEvent(
        id: _uuid.v4(),
        timestamp: DateTime.now(),
        level: level,
        message: message,
        recordingId: recordingId,
      ),
    );
  }

  void add(LogEvent event) {
    _events = _capped(<LogEvent>[event, ..._events]);
    notifyListeners();
    _scheduleFlush();
  }

  Future<void> clear() async {
    _events = <LogEvent>[];
    notifyListeners();
    // Route through the coalescing flush so this write can't race an in-flight
    // one over the shared `.tmp` file (double rename → ENOENT).
    _scheduleFlush();
  }

  List<LogEvent> _capped(List<LogEvent> events) {
    if (events.length <= capacity) return events;
    return events.sublist(0, capacity);
  }

  /// Single-flight flush: a write already in progress just marks the buffer
  /// dirty and the running flush picks up the newest snapshot afterwards.
  void _scheduleFlush() {
    final LogArchive? archive = _archive;
    if (archive == null) return;
    if (_isFlushing) {
      _isDirty = true;
      return;
    }
    _isFlushing = true;
    Future<void>(() async {
      try {
        do {
          _isDirty = false;
          await archive.save(_events);
        } while (_isDirty);
      } catch (_) {
        // Logging must never break the app; a failed flush is dropped and the
        // in-memory buffer stays authoritative for this session.
      } finally {
        _isFlushing = false;
      }
    });
  }
}

/// `logs.json` in the app documents `recordings/` folder, atomic via
/// `.tmp` + `rename`, same as the recordings index.
class FileLogArchive implements LogArchive {
  Future<File> _file() async {
    final Directory appDirectory = await getApplicationDocumentsDirectory();
    final Directory directory =
        Directory(p.join(appDirectory.path, 'recordings'));
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return File(p.join(directory.path, 'logs.json'));
  }

  @override
  Future<List<LogEvent>> load() async {
    final File file = await _file();
    if (!await file.exists()) return <LogEvent>[];

    final String raw = await file.readAsString();
    if (raw.trim().isEmpty) return <LogEvent>[];

    final dynamic decoded = jsonDecode(raw);
    if (decoded is! List<dynamic>) return <LogEvent>[];

    return decoded
        .whereType<Map<String, dynamic>>()
        .map(LogEvent.fromJson)
        .toList();
  }

  @override
  Future<void> save(List<LogEvent> events) async {
    final File file = await _file();
    final String payload = jsonEncode(
      events.map((LogEvent event) => event.toJson()).toList(),
    );

    final File temporary = File('${file.path}.tmp');
    await temporary.writeAsString(payload, flush: true);
    await temporary.rename(file.path);
  }
}
