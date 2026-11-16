import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:augustyniak_capture/features/recordings/data/system_clipboard_sink.dart';
import 'package:flutter_test/flutter_test.dart';

/// A `wl-copy` that records what it was fed and exits with [code], or never
/// exits when [code] is null.
class _FakeProcess implements Process {
  _FakeProcess(this.code);
  final int? code;
  final List<int> fed = <int>[];
  bool killed = false;
  late final IOSink _stdin = IOSink(
    StreamController<List<int>>()..stream.listen(fed.addAll),
  );

  @override
  IOSink get stdin => _stdin;

  @override
  Future<int> get exitCode =>
      code == null ? Completer<int>().future : Future<int>.value(code);

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => killed = true;

  @override
  int get pid => 1;

  @override
  Stream<List<int>> get stdout => const Stream<List<int>>.empty();

  @override
  Stream<List<int>> get stderr => const Stream<List<int>>.empty();
}

void main() {
  const Map<String, String> wayland = <String, String>{
    'WAYLAND_DISPLAY': 'wayland-0',
  };
  const String text = 'zażółć gęślą jaźń';

  late List<String> gtk;
  late List<List<String>> started;
  Future<void> recordGtk(String t) async => gtk.add(t);

  setUp(() {
    gtk = <String>[];
    started = <List<String>>[];
  });

  SystemClipboardSink sink(
    _FakeProcess? process, {
    bool isLinux = true,
    Map<String, String> environment = wayland,
  }) => SystemClipboardSink(
    isLinux: isLinux,
    environment: environment,
    fallback: recordGtk,
    timeout: const Duration(milliseconds: 50),
    startProcess: (String exe, List<String> args) async {
      started.add(<String>[exe, ...args]);
      if (process == null) throw ProcessException(exe, args, 'not found', 2);
      return process;
    },
  );

  test('Wayland: the text goes to wl-copy as UTF-8, not to GTK', () async {
    final _FakeProcess process = _FakeProcess(0);

    await sink(process).copy(text);

    expect(started, <List<String>>[
      <String>['wl-copy', '--type', 'text/plain;charset=utf-8'],
    ]);
    expect(utf8.decode(process.fed), text);
    expect(gtk, isEmpty);
  });

  test('a failing wl-copy throws, so the caller logs the truth', () async {
    await expectLater(
      sink(_FakeProcess(1)).copy(text),
      throwsA(isA<ProcessException>()),
    );
    expect(gtk, isEmpty);
  });

  test('a wl-copy that never exits is killed and reported', () async {
    final _FakeProcess process = _FakeProcess(null);

    await expectLater(
      sink(process).copy(text),
      throwsA(isA<TimeoutException>()),
    );
    expect(process.killed, isTrue);
  });

  test('no wl-copy installed: falls back to GTK', () async {
    await sink(null).copy(text);

    expect(gtk, <String>[text]);
  });

  test('X11 and other platforms keep GTK and start no process', () async {
    await sink(
      _FakeProcess(0),
      environment: const <String, String>{},
    ).copy(text);
    await sink(_FakeProcess(0), isLinux: false).copy(text);

    expect(started, isEmpty);
    expect(gtk, <String>[text, text]);
  });
}
