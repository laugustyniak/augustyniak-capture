import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:augustyniak_capture/features/recordings/data/system_screenshot_taker.dart';
import 'package:augustyniak_capture/features/recordings/domain/screenshot_taker.dart';

/// Answers each executable from a table and records every call, so the
/// command lines can be checked without a display server.
class _FakeRun {
  _FakeRun(this.answers);

  /// Executable → result. A missing entry behaves like a tool not on `PATH`.
  final Map<String, ProcessResult> answers;
  final List<List<String>> calls = <List<String>>[];

  Future<ProcessResult> call(String executable, List<String> arguments) async {
    calls.add(<String>[executable, ...arguments]);
    final ProcessResult? answer = answers[executable];
    if (answer == null) {
      throw ProcessException(executable, arguments, 'No such file', 2);
    }
    return answer;
  }
}

ProcessResult _ok([String stdout = '']) => ProcessResult(1, 0, stdout, '');
ProcessResult _exit(int code) => ProcessResult(1, code, '', '');

void main() {
  final File target = File('/media/abc.png');

  test(
    'macOS runs the interactive region/window picker into the target',
    () async {
      final _FakeRun run = _FakeRun(<String, ProcessResult>{
        'screencapture': _ok(),
      });
      final ScreenshotTaker taker = SystemScreenshotTaker(
        operatingSystem: 'macos',
        run: run.call,
      );

      expect(taker.isAvailable, isTrue);
      await taker.capture(target);

      expect(run.calls, <List<String>>[
        <String>['screencapture', '-i', '-x', target.path],
      ]);
    },
  );

  test('a non-zero exit is a cancelled selection, not an error', () async {
    final _FakeRun run = _FakeRun(<String, ProcessResult>{
      'screencapture': _exit(1),
    });

    await SystemScreenshotTaker(
      operatingSystem: 'macos',
      run: run.call,
    ).capture(target);

    expect(run.calls, hasLength(1));
  });

  test('Linux prefers gnome-screenshot area selection', () async {
    final _FakeRun run = _FakeRun(<String, ProcessResult>{
      'gnome-screenshot': _ok(),
      'slurp': _ok('10,20 300x200\n'),
      'grim': _ok(),
    });

    await SystemScreenshotTaker(
      operatingSystem: 'linux',
      run: run.call,
    ).capture(target);

    expect(run.calls, <List<String>>[
      <String>['gnome-screenshot', '-a', '-f', target.path],
    ]);
  });

  test(
    'Linux falls back to slurp + grim when gnome-screenshot is absent',
    () async {
      final _FakeRun run = _FakeRun(<String, ProcessResult>{
        'slurp': _ok('10,20 300x200\n'),
        'grim': _ok(),
      });

      await SystemScreenshotTaker(
        operatingSystem: 'linux',
        run: run.call,
      ).capture(target);

      expect(run.calls, <List<String>>[
        <String>['gnome-screenshot', '-a', '-f', target.path],
        <String>['slurp'],
        <String>['grim', '-g', '10,20 300x200', target.path],
      ]);
    },
  );

  test('an Escape in slurp writes nothing and calls grim never', () async {
    final _FakeRun run = _FakeRun(<String, ProcessResult>{
      'slurp': _exit(1),
      'grim': _ok(),
    });

    await SystemScreenshotTaker(
      operatingSystem: 'linux',
      run: run.call,
    ).capture(target);

    expect(run.calls.map((List<String> c) => c.first), <String>[
      'gnome-screenshot',
      'slurp',
    ]);
  });

  test('Linux with no screenshot tool at all says so', () async {
    final _FakeRun run = _FakeRun(<String, ProcessResult>{});

    await expectLater(
      SystemScreenshotTaker(
        operatingSystem: 'linux',
        run: run.call,
      ).capture(target),
      throwsA(isA<ScreenshotUnavailableException>()),
    );
  });

  test(
    'platforms with no file-writing tool are unavailable and throw at use',
    () async {
      final _FakeRun run = _FakeRun(<String, ProcessResult>{});
      final ScreenshotTaker taker = SystemScreenshotTaker(
        operatingSystem: 'windows',
        run: run.call,
      );

      expect(taker.isAvailable, isFalse);
      await expectLater(
        taker.capture(target),
        throwsA(isA<ScreenshotUnavailableException>()),
      );
      expect(run.calls, isEmpty);
    },
  );

  test('the default taker degrades at use, never at wiring time', () async {
    const ScreenshotTaker taker = UnavailableScreenshotTaker();

    expect(taker.isAvailable, isFalse);
    await expectLater(
      taker.capture(target),
      throwsA(isA<ScreenshotUnavailableException>()),
    );
  });
}
