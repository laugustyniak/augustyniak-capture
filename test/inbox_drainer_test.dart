import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:augustyniak_capture/features/logs/domain/log_event.dart';
import 'package:augustyniak_capture/features/recordings/data/inbox_drainer.dart';

class _RecordingLogSink implements LogSink {
  final List<String> messages = <String>[];

  @override
  void log(
    String message, {
    LogLevel level = LogLevel.info,
    String? recordingId,
  }) {
    messages.add(message);
  }
}

class _ThrowingLogSink implements LogSink {
  @override
  void log(
    String message, {
    LogLevel level = LogLevel.info,
    String? recordingId,
  }) => throw StateError('sink broke');
}

void main() {
  const String idA = '123e4567-e89b-42d3-a456-426614174000';
  const String idB = '223e4567-e89b-42d3-a456-426614174000';
  late Directory root;
  late Directory inbox;
  late _RecordingLogSink logs;
  late List<String> seen;

  File put(String name, String content, {int ageSeconds = 0}) {
    final File f = File(p.join(inbox.path, name))..writeAsStringSync(content);
    f.setLastModifiedSync(
      DateTime.now().subtract(Duration(seconds: ageSeconds)),
    );
    return f;
  }

  InboxDrainer drainer(Future<bool> Function(String, String) ingest) =>
      InboxDrainer(inbox: inbox, ingest: ingest, logSink: logs);

  setUp(() {
    root = Directory.systemTemp.createTempSync('augustyniak_capture_inbox_');
    inbox = Directory(p.join(root.path, 'inbox'))..createSync();
    logs = _RecordingLogSink();
    seen = <String>[];
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('a missing directory is a no-op', () async {
    inbox.deleteSync();
    expect(await drainer((_, _) async => true).drain(), 0);
  });

  test('ingests a valid file with its uuid and deletes it on true', () async {
    final File f = put('$idA.txt', 'buy milk');
    final int n = await drainer((String id, String body) async {
      seen.add('$id|$body');
      return true;
    }).drain();
    expect(n, 1);
    expect(seen, <String>['$idA|buy milk']);
    expect(f.existsSync(), isFalse);
  });

  test('ignores .tmp and other extensions', () async {
    final File tmp = put('$idA.txt.tmp', 'half');
    final File other = put('$idB.md', 'x');
    final int n = await drainer((String id, String body) async {
      seen.add(id);
      return true;
    }).drain();
    expect(n, 0);
    expect(seen, isEmpty);
    expect(tmp.existsSync(), isTrue);
    expect(other.existsSync(), isTrue);
  });

  test('a non-uuid name is skipped, logged and kept', () async {
    final File f = put('notes.txt', 'hi');
    final int n = await drainer((String id, String body) async {
      seen.add(id);
      return true;
    }).drain();
    expect(n, 0);
    expect(seen, isEmpty);
    expect(f.existsSync(), isTrue);
    expect(logs.messages, isNotEmpty);
  });

  test('oldest-modified file is ingested first', () async {
    put('$idA.txt', 'new', ageSeconds: 10);
    put('$idB.txt', 'old', ageSeconds: 100);
    await drainer((String id, String body) async {
      seen.add(body);
      return true;
    }).drain();
    expect(seen, <String>['old', 'new']);
  });

  test('empty or whitespace content is logged and deleted', () async {
    final File f = put('$idA.txt', '  \n ');
    final int n = await drainer((String id, String body) async {
      seen.add(id);
      return true;
    }).drain();
    expect(n, 0);
    expect(seen, isEmpty);
    expect(f.existsSync(), isFalse);
    expect(logs.messages, isNotEmpty);
  });

  test('a stale .tmp is deleted, a fresh one is left alone', () async {
    final File stale = put('$idA.txt.tmp', 'half', ageSeconds: 2 * 3600);
    final File fresh = put('$idB.txt.tmp', 'half', ageSeconds: 60);
    await drainer((_, _) async => true).drain();
    expect(stale.existsSync(), isFalse);
    expect(fresh.existsSync(), isTrue);
  });

  test('unreadable (invalid utf8) content is logged and kept', () async {
    final File f = File(p.join(inbox.path, '$idA.txt'))
      ..writeAsBytesSync(<int>[0xff, 0xfe, 0xfd]);
    final int n = await drainer((String id, String body) async {
      seen.add(id);
      return true;
    }).drain();
    expect(n, 0);
    expect(seen, isEmpty);
    expect(f.existsSync(), isTrue);
  });

  test('ingest returning false keeps the file', () async {
    final File f = put('$idA.txt', 'busy');
    expect(await drainer((_, _) async => false).drain(), 0);
    expect(f.existsSync(), isTrue);
  });

  test('ingest throwing keeps the file and the next one still runs', () async {
    final File a = put('$idA.txt', 'boom', ageSeconds: 100);
    final File b = put('$idB.txt', 'fine', ageSeconds: 10);
    final int n = await drainer((String id, String body) async {
      if (id == idA) throw StateError('boom');
      return true;
    }).drain();
    expect(n, 1);
    expect(a.existsSync(), isTrue);
    expect(b.existsSync(), isFalse);
    expect(logs.messages, isNotEmpty);
  });

  test('a throwing log sink never breaks the drain', () async {
    final File f = put('notes.txt', 'hi');
    final InboxDrainer d = InboxDrainer(
      inbox: inbox,
      ingest: (_, _) async => true,
      logSink: _ThrowingLogSink(),
    );
    expect(await d.drain(), 0);
    expect(f.existsSync(), isTrue);
  });

  test('a concurrent drain returns 0 instead of double-processing', () async {
    put('$idA.txt', 'once');
    final Completer<void> gate = Completer<void>();
    int calls = 0;
    final InboxDrainer d = drainer((String id, String body) async {
      calls++;
      await gate.future;
      return true;
    });
    final Future<int> first = d.drain();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(await d.drain(), 0);
    gate.complete();
    expect(await first, 1);
    expect(calls, 1);
    // The guard is released afterwards.
    put('$idB.txt', 'later');
    expect(await d.drain(), 1);
  });

  test(
    'an entry that cannot be stat-ed does not stop the other files',
    () async {
      // A dangling link stands in for a producer renaming its .tmp between the
      // directory listing and the stat: listed, then gone.
      Link(
        p.join(inbox.path, '$idA.txt.tmp'),
      ).createSync(p.join(root.path, 'gone'));
      put('$idB.txt', 'still ingested');
      final int n = await drainer((String id, String body) async {
        seen.add(body);
        return true;
      }).drain();
      expect(n, 1);
      expect(seen, <String>['still ingested']);
    },
  );

  test('a file removed by an earlier ingest does not stop the pass', () async {
    final File later = put('$idB.txt', 'gone by then', ageSeconds: 10);
    put('$idA.txt', 'first', ageSeconds: 100);
    final int n = await drainer((String id, String body) async {
      if (id == idA) later.deleteSync();
      seen.add(id);
      return true;
    }).drain();
    expect(n, 1);
    expect(seen, <String>[idA, idB].sublist(0, 1) + <String>[]);
  });

  group('audio (.m4a)', () {
    InboxDrainer audioDrainer(
      Future<bool> Function(String, File)? ingestAudio,
    ) => InboxDrainer(
      inbox: inbox,
      ingest: (_, _) async => true,
      ingestAudio: ingestAudio,
      logSink: logs,
    );

    test('m4a is ingested and deleted on true', () async {
      final File f = put('$idA.m4a', 'audio-bytes');
      final int n = await audioDrainer((String id, File file) async {
        seen.add('$id|${file.path}');
        return true;
      }).drain();
      expect(n, 1);
      expect(seen, <String>['$idA|${f.path}']);
      expect(f.existsSync(), isFalse);
    });

    test('m4a is kept on false', () async {
      final File f = put('$idA.m4a', 'audio-bytes');
      final int n = await audioDrainer((_, _) async => false).drain();
      expect(n, 0);
      expect(f.existsSync(), isTrue);
    });

    test('m4a with a non-uuid name is skipped', () async {
      final File f = put('notes.m4a', 'audio-bytes');
      final int n = await audioDrainer((String id, File file) async {
        seen.add(id);
        return true;
      }).drain();
      expect(n, 0);
      expect(seen, isEmpty);
      expect(f.existsSync(), isTrue);
    });

    test('m4a is ignored when ingestAudio is null', () async {
      final File f = put('$idA.m4a', 'audio-bytes');
      final int n = await audioDrainer(null).drain();
      expect(n, 0);
      expect(f.existsSync(), isTrue);
    });

    test('m4a ingest throwing keeps the file and continues', () async {
      final File bad = put('$idA.m4a', 'x', ageSeconds: 100);
      final File good = put('$idB.m4a', 'y', ageSeconds: 10);
      final int n = await audioDrainer((String id, File file) async {
        if (id == idA) throw StateError('boom');
        return true;
      }).drain();
      expect(n, 1);
      expect(bad.existsSync(), isTrue);
      expect(good.existsSync(), isFalse);
    });

    test('an empty m4a is not treated as an empty note', () async {
      final File f = put('$idA.m4a', '');
      await audioDrainer((_, _) async => false).drain();
      expect(f.existsSync(), isTrue);
    });
  });

  test(
    'a stale m4a.tmp is kept and logged, a stale txt.tmp is swept',
    () async {
      final File car = put('$idA.m4a.tmp', 'partial', ageSeconds: 7200);
      final File txt = put('$idB.txt.tmp', 'partial', ageSeconds: 7200);
      await drainer((_, _) async => true).drain();
      expect(car.existsSync(), isTrue);
      expect(txt.existsSync(), isFalse);
      expect(
        logs.messages.where((String m) => m.contains('m4a.tmp')),
        hasLength(1),
      );
    },
  );
}
