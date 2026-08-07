import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../domain/log_event.dart';

abstract interface class LogArchive {
  Future<List<LogEvent>> load();
  Future<void> save(List<LogEvent> events);
}

class LogStore extends ChangeNotifier implements LogSink {
  LogStore({LogArchive? archive, this.capacity = 500})
      : _archive = archive ?? const SqliteLogArchive();

  final LogArchive? _archive;
  final int capacity;
  final Uuid _uuid = const Uuid();

  List<LogEvent> _events = <LogEvent>[];
  bool _isFlushing = false;
  bool _isDirty = false;
  bool _disposed = false;

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
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @override
  void log(
    String message, {
    LogLevel level = LogLevel.info,
    String? recordingId,
  }) {
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
    if (!_disposed) notifyListeners();
    _scheduleFlush();
  }

  Future<void> clear() async {
    _events = <LogEvent>[];
    if (!_disposed) notifyListeners();
    _scheduleFlush();
  }

  List<LogEvent> _capped(List<LogEvent> events) {
    if (events.length <= capacity) return events;
    return events.sublist(0, capacity);
  }

  void _scheduleFlush() {
    final LogArchive? archive = _archive;
    if (archive == null) return;
    if (_isFlushing) {
      _isDirty = true;
      return;
    }
    _isFlushing = true;
    scheduleMicrotask(() async {
      try {
        do {
          _isDirty = false;
          await archive.save(_events);
        } while (_isDirty);
      } catch (_) {
      } finally {
        _isFlushing = false;
      }
    });
  }
}

class SqliteLogArchive implements LogArchive {
  const SqliteLogArchive();

  @override
  Future<List<LogEvent>> load() async {
    try {
      final AppDatabase db = await AppDatabase.getInstance();
      final ResultSet results = db.rawDb.select('''
        SELECT id, timestamp, level, message, recording_id
        FROM logs
        ORDER BY timestamp DESC
        LIMIT 500;
      ''');

      if (results.isEmpty) {
        return await FileLogArchive().load();
      }

      final List<LogEvent> events = <LogEvent>[];
      for (final Row row in results) {
        final String levelStr = row['level'] as String? ?? 'info';
        final LogLevel level = LogLevel.values.firstWhere(
          (e) => e.name == levelStr,
          orElse: () => LogLevel.info,
        );

        events.add(
          LogEvent(
            id: row['id'] as String,
            timestamp: DateTime.fromMillisecondsSinceEpoch(row['timestamp'] as int),
            level: level,
            message: row['message'] as String,
            recordingId: row['recording_id'] as String?,
          ),
        );
      }
      return events;
    } catch (_) {
      return <LogEvent>[];
    }
  }

  @override
  Future<void> save(List<LogEvent> events) async {
    try {
      final AppDatabase db = await AppDatabase.getInstance();
      db.rawDb.execute('BEGIN TRANSACTION;');
      db.rawDb.execute('DELETE FROM logs;');
      final PreparedStatement stmt = db.rawDb.prepare('''
        INSERT INTO logs (id, timestamp, level, message, recording_id)
        VALUES (?, ?, ?, ?, ?);
      ''');
      for (final LogEvent e in events) {
        stmt.execute(<Object?>[
          e.id,
          e.timestamp.millisecondsSinceEpoch,
          e.level.name,
          e.message,
          e.recordingId,
        ]);
      }
      stmt.dispose();
      db.rawDb.execute('COMMIT;');
    } catch (_) {
      // Best-effort logging flush
    }
  }
}

class FileLogArchive implements LogArchive {
  Future<File> _file() async {
    final Directory appDirectory = await getApplicationDocumentsDirectory();
    final Directory directory = Directory(
      p.join(appDirectory.path, 'recordings'),
    );
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return File(p.join(directory.path, 'logs.json'));
  }

  @override
  Future<List<LogEvent>> load() async {
    try {
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
    } catch (_) {
      return <LogEvent>[];
    }
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
