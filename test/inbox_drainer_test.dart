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

  test('empty or whitespace content is logged and kept', () async {
    final File f = put('$idA.txt', '  \n ');
    final int n = await drainer((String id, String body) async {
      seen.add(id);
      return true;
    }).drain();
    expect(n, 0);
    expect(seen, isEmpty);
    expect(f.existsSync(), isTrue);
    expect(logs.messages, isNotEmpty);
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
}
