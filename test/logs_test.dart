import 'package:flutter_test/flutter_test.dart';
import 'package:audivoa_core/features/logs/data/log_store.dart';
import 'package:audivoa_core/features/logs/domain/log_event.dart';

void main() {
  group('LogEvent', () {
    test('JSON round-trip preserves every field', () {
      final LogEvent original = LogEvent(
        id: 'e1',
        timestamp: DateTime.utc(2026, 7, 25, 10, 15, 30),
        level: LogLevel.error,
        message: 'Transkrypcja nieudana',
        recordingId: 'rec-1',
      );

      final LogEvent restored = LogEvent.fromJson(original.toJson());

      expect(restored.id, 'e1');
      expect(restored.timestamp, original.timestamp);
      expect(restored.level, LogLevel.error);
      expect(restored.message, 'Transkrypcja nieudana');
      expect(restored.recordingId, 'rec-1');
    });

    test('unknown or missing level degrades to info', () {
      final LogEvent unknown = LogEvent.fromJson(<String, dynamic>{
        'id': 'e',
        'timestamp': DateTime.utc(2026).toIso8601String(),
        'level': 'critical',
        'message': 'x',
      });
      final LogEvent missing = LogEvent.fromJson(<String, dynamic>{
        'id': 'e2',
        'timestamp': DateTime.utc(2026).toIso8601String(),
        'message': 'y',
      });

      expect(unknown.level, LogLevel.info);
      expect(missing.level, LogLevel.info);
      expect(missing.message, 'y');
    });
  });

  group('LogStore', () {
    test('log() prepends newest-first', () {
      final LogStore store = LogStore();
      store.log('first');
      store.log('second');

      expect(store.events, hasLength(2));
      expect(store.events.first.message, 'second');
      expect(store.events.last.message, 'first');
    });

    test('evicts oldest beyond capacity, keeping newest', () {
      final LogStore store = LogStore(capacity: 3);
      for (int i = 0; i < 5; i++) {
        store.log('msg-$i');
      }

      expect(store.events, hasLength(3));
      expect(store.events.first.message, 'msg-4');
      expect(store.events.last.message, 'msg-2');
    });

    test('eventsAtLevel filters, null returns all', () {
      final LogStore store = LogStore();
      store.log('a', level: LogLevel.info);
      store.log('b', level: LogLevel.error);
      store.log('c', level: LogLevel.error);

      expect(store.eventsAtLevel(null), hasLength(3));
      expect(store.eventsAtLevel(LogLevel.error), hasLength(2));
      expect(store.eventsAtLevel(LogLevel.warn), isEmpty);
    });

    test('countAtLevel counts by level', () {
      final LogStore store = LogStore();
      store.log('a', level: LogLevel.warn);
      store.log('b', level: LogLevel.warn);
      store.log('c', level: LogLevel.info);

      expect(store.countAtLevel(LogLevel.warn), 2);
      expect(store.countAtLevel(LogLevel.info), 1);
      expect(store.countAtLevel(LogLevel.error), 0);
    });

    test('clear empties the buffer', () async {
      final LogStore store = LogStore();
      store.log('a');
      store.log('b');
      await store.clear();

      expect(store.events, isEmpty);
    });

    test('log() carries level and recordingId onto the event', () {
      final LogStore store = LogStore();
      store.log('boom', level: LogLevel.error, recordingId: 'rec-9');

      final LogEvent event = store.events.first;
      expect(event.level, LogLevel.error);
      expect(event.recordingId, 'rec-9');
      expect(event.message, 'boom');
    });

    test('notifies listeners on add', () {
      final LogStore store = LogStore();
      int notifications = 0;
      store.addListener(() => notifications++);

      store.log('a');

      expect(notifications, 1);
    });

    test('a store without an archive stays in memory and never throws', () {
      final LogStore store = LogStore();
      store.add(
        LogEvent(
          id: 'x',
          timestamp: DateTime.utc(2026),
          level: LogLevel.info,
          message: 'bez archiwum',
        ),
      );

      expect(store.events.single.message, 'bez archiwum');
    });

    test('initialize loads and caps what the archive returns', () async {
      final _FakeArchive archive = _FakeArchive(
        initial: List<LogEvent>.generate(
          5,
          (int index) => LogEvent(
            id: 'e$index',
            timestamp: DateTime.utc(2026),
            level: LogLevel.info,
            message: 'stored-$index',
          ),
        ),
      );
      final LogStore store = LogStore(archive: archive, capacity: 2);

      await store.initialize();

      expect(store.events, hasLength(2));
      expect(store.events.first.message, 'stored-0');
    });

    test('coalesces bursts of appends into fewer archive writes', () async {
      final _FakeArchive archive = _FakeArchive();
      final LogStore store = LogStore(archive: archive);

      for (int i = 0; i < 20; i++) {
        store.log('burst-$i');
      }
      // Let the single-flight flush drain.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(store.events, hasLength(20));
      expect(archive.saveCount, lessThan(20));
      expect(archive.lastSaved.first.message, 'burst-19');
    });
  });
}

class _FakeArchive implements LogArchive {
  _FakeArchive({this.initial = const <LogEvent>[]});

  final List<LogEvent> initial;
  List<LogEvent> lastSaved = <LogEvent>[];
  int saveCount = 0;

  @override
  Future<List<LogEvent>> load() async => initial;

  @override
  Future<void> save(List<LogEvent> events) async {
    saveCount++;
    lastSaved = List<LogEvent>.from(events);
  }
}
