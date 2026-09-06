import 'dart:io';

import 'package:augustyniak_capture/features/clipboard/data/xdotool_auto_paste.dart';
import 'package:augustyniak_capture/features/clipboard/domain/auto_paste.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records every `xdotool` invocation and answers with scripted results.
///
/// Pure Dart — no X server, no binary on `PATH`. What is being pinned is the
/// order and the arguments, both of which are the whole correctness story here:
/// a paste sent before the activation lands, or one sent with the hotkey's
/// modifiers still held, reaches the wrong window or types the wrong thing.
class _FakeXdotool {
  _FakeXdotool({this.active = '4194309'});

  /// What `getactivewindow` prints. Null makes it exit non-zero instead.
  final String? active;

  bool activateFails = false;
  bool throwOnRun = false;

  final List<List<String>> calls = <List<String>>[];

  Future<ProcessResult> run(String executable, List<String> arguments) async {
    if (throwOnRun) {
      throw ProcessException(executable, arguments, 'No such file', 2);
    }
    calls.add(<String>[executable, ...arguments]);
    if (arguments.first == 'getactivewindow') {
      final String? id = active;
      return id == null
          ? ProcessResult(1, 1, '', 'no active window')
          : ProcessResult(1, 0, '$id\n', '');
    }
    if (arguments.first == 'windowactivate') {
      return activateFails
          ? ProcessResult(1, 1, '', 'window not found')
          : ProcessResult(1, 0, '', '');
    }
    return ProcessResult(1, 0, '', '');
  }
}

void main() {
  group('XdotoolAutoPaste', () {
    test('activates the remembered window, then sends ctrl+v', () async {
      final _FakeXdotool xdotool = _FakeXdotool();
      final XdotoolAutoPaste paster = XdotoolAutoPaste(run: xdotool.run);

      await paster.rememberTarget();
      expect(paster.target, '4194309');

      await paster.pasteToTarget();

      expect(xdotool.calls, <List<String>>[
        <String>['xdotool', 'getactivewindow'],
        // `--sync` blocks until the activation has actually happened. Without
        // it the keystroke below races the window manager and can land in the
        // palette that is still on screen.
        <String>['xdotool', 'windowactivate', '--sync', '4194309'],
        // `--clearmodifiers` releases the Ctrl+Alt the user is still physically
        // holding from the hotkey; without it the target sees Ctrl+Alt+V.
        <String>['xdotool', 'key', '--clearmodifiers', 'ctrl+v'],
      ]);
    });

    test('pasting twice only reaches the window once', () async {
      final _FakeXdotool xdotool = _FakeXdotool();
      final XdotoolAutoPaste paster = XdotoolAutoPaste(run: xdotool.run);

      await paster.rememberTarget();
      await paster.pasteToTarget();
      xdotool.calls.clear();
      await paster.pasteToTarget();

      // The target is consumed, not kept: a second paste would aim at a window
      // recorded for a palette the user has already closed.
      expect(xdotool.calls, isEmpty);
      expect(paster.target, isNull);
    });

    test('a window that has gone away never receives the keystroke', () async {
      final _FakeXdotool xdotool = _FakeXdotool()..activateFails = true;
      final XdotoolAutoPaste paster = XdotoolAutoPaste(run: xdotool.run);

      await paster.rememberTarget();
      await paster.pasteToTarget();

      expect(
        xdotool.calls.any((List<String> call) => call.contains('key')),
        isFalse,
        reason: 'Ctrl+V would go to whatever inherited the focus instead.',
      );
    });

    test('no active window to record means no paste attempt', () async {
      final _FakeXdotool xdotool = _FakeXdotool(active: null);
      final XdotoolAutoPaste paster = XdotoolAutoPaste(run: xdotool.run);

      await paster.rememberTarget();
      expect(paster.target, isNull);

      xdotool.calls.clear();
      await paster.pasteToTarget();
      expect(xdotool.calls, isEmpty);
    });

    test('a window id of 0 is the same fact as no window', () async {
      // What `xdotool` prints with nothing focused, and under Wayland where it
      // can see nothing at all.
      final XdotoolAutoPaste paster = XdotoolAutoPaste(
        run: _FakeXdotool(active: '0').run,
      );

      await paster.rememberTarget();

      expect(paster.target, isNull);
    });

    test('a non-numeric answer is refused rather than passed on', () async {
      // The value becomes an argument to a second process; anything that is not
      // a window id means `xdotool` reported something else entirely.
      final XdotoolAutoPaste paster = XdotoolAutoPaste(
        run: _FakeXdotool(active: 'Cannot open display').run,
      );

      await paster.rememberTarget();

      expect(paster.target, isNull);
    });

    test('a missing binary degrades instead of throwing', () async {
      final _FakeXdotool xdotool = _FakeXdotool()..throwOnRun = true;
      final XdotoolAutoPaste paster = XdotoolAutoPaste(run: xdotool.run);

      // Same degradation as `SystemWindowPresenter` and the ffmpeg processors:
      // the entry is on the clipboard, and the user pastes it themselves.
      await paster.rememberTarget();
      await paster.pasteToTarget();

      expect(paster.target, isNull);
    });

    test('a failure while pasting does not escape', () async {
      final _FakeXdotool xdotool = _FakeXdotool();
      final XdotoolAutoPaste paster = XdotoolAutoPaste(run: xdotool.run);

      await paster.rememberTarget();
      xdotool.throwOnRun = true;

      await expectLater(paster.pasteToTarget(), completes);
    });
  });

  group('DisabledAutoPaste', () {
    test('rememberTarget and pasteToTarget complete silently', () async {
      const DisabledAutoPaste paster = DisabledAutoPaste();
      await expectLater(paster.rememberTarget(), completes);
      await expectLater(paster.pasteToTarget(), completes);
    });
  });

  group('ChannelAutoPaste', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const MethodChannel channel = MethodChannel(
      'ai.augustyniak.capture/clipboard',
    );

    test('invokes autoPaste method on channel', () async {
      const ChannelAutoPaste paster = ChannelAutoPaste();
      final List<MethodCall> calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            calls.add(call);
            return true;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      await paster.rememberTarget();
      expect(calls, isEmpty);

      await paster.pasteToTarget();
      expect(calls, hasLength(1));
      expect(calls.first.method, 'autoPaste');
    });
  });
}
