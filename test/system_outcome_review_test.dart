import 'dart:io';

import 'package:augustyniak_capture/features/command/data/system_outcome_review.dart';
import 'package:augustyniak_capture/features/recordings/domain/route_record.dart';
import 'package:augustyniak_capture/features/command/domain/outcome_review.dart';
import 'package:flutter_test/flutter_test.dart';

class _Call {
  _Call(this.executable, this.arguments, this.environment);
  final String executable;
  final List<String> arguments;
  final Map<String, String>? environment;
}

class _FakeRunner {
  _FakeRunner({this.exitCode = 0});
  final int exitCode;
  final List<_Call> calls = <_Call>[];

  Future<int> call(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
  }) async {
    calls.add(_Call(executable, arguments, environment));
    return exitCode;
  }
}

const String _summary = 'Agent result: done. Opened pull request 7 in a/b.';

const OutcomeAnnouncement _announcement = OutcomeAnnouncement(
  recordingId: 'abc',
  state: CommandState.done,
  summary: _summary,
);

void main() {
  group('SystemOutcomeSpeaker', () {
    test('macOS speaks through say, the text as one argument', () async {
      final _FakeRunner runner = _FakeRunner();
      final SystemOutcomeSpeaker speaker = SystemOutcomeSpeaker(
        operatingSystem: 'macos',
        environment: const <String, String>{},
        runProcess: runner.call,
        exists: (String path) => path == '/usr/bin/say',
      );

      expect(await speaker.isAvailable(), isTrue);
      await speaker.speak(_summary);

      expect(runner.calls.single.executable, '/usr/bin/say');
      expect(runner.calls.single.arguments, <String>[_summary]);
    });

    test('Linux prefers spd-say and waits for it to finish', () async {
      final _FakeRunner runner = _FakeRunner();
      final SystemOutcomeSpeaker speaker = SystemOutcomeSpeaker(
        operatingSystem: 'linux',
        environment: const <String, String>{'PATH': '/opt/bin'},
        runProcess: runner.call,
        exists: (String path) =>
            path == '/usr/bin/spd-say' || path == '/opt/bin/espeak',
      );

      await speaker.speak(_summary);

      expect(runner.calls.single.executable, '/usr/bin/spd-say');
      expect(runner.calls.single.arguments, <String>['-w', _summary]);
    });

    test(
      'Linux falls back to espeak when speech-dispatcher is absent',
      () async {
        final _FakeRunner runner = _FakeRunner();
        final SystemOutcomeSpeaker speaker = SystemOutcomeSpeaker(
          operatingSystem: 'linux',
          environment: const <String, String>{'PATH': '/opt/bin'},
          runProcess: runner.call,
          exists: (String path) => path == '/opt/bin/espeak',
        );

        await speaker.speak(_summary);

        expect(runner.calls.single.executable, '/opt/bin/espeak');
        expect(runner.calls.single.arguments, <String>[_summary]);
      },
    );

    test(
      'Windows passes the text in the environment, never the command',
      () async {
        final _FakeRunner runner = _FakeRunner();
        final SystemOutcomeSpeaker speaker = SystemOutcomeSpeaker(
          operatingSystem: 'windows',
          environment: const <String, String>{'SystemRoot': r'C:\Windows'},
          runProcess: runner.call,
          exists: (String path) => path.endsWith('powershell.exe'),
        );

        await speaker.speak(_summary);

        final _Call call = runner.calls.single;
        expect(call.executable, endsWith('powershell.exe'));
        expect(call.arguments.join(' '), isNot(contains(_summary)));
        expect(call.environment, <String, String>{
          outcomeSpeechVariable: _summary,
        });
      },
    );

    test('no engine, or a phone, is unavailable and speaks nothing', () async {
      for (final String os in <String>['linux', 'android', 'ios']) {
        final _FakeRunner runner = _FakeRunner();
        final SystemOutcomeSpeaker speaker = SystemOutcomeSpeaker(
          operatingSystem: os,
          environment: const <String, String>{},
          runProcess: runner.call,
          exists: (String path) => false,
        );

        expect(await speaker.isAvailable(), isFalse, reason: os);
        await expectLater(speaker.speak(_summary), throwsUnsupportedError);
        expect(runner.calls, isEmpty);
      }
    });

    test('an engine that fails is reported, not read as spoken', () async {
      final SystemOutcomeSpeaker speaker = SystemOutcomeSpeaker(
        operatingSystem: 'macos',
        environment: const <String, String>{},
        runProcess: _FakeRunner(exitCode: 1).call,
        exists: (String path) => true,
      );

      await expectLater(
        speaker.speak(_summary),
        throwsA(isA<ProcessException>()),
      );
    });
  });

  group('SystemOutcomeNotifier', () {
    test('macOS hands the title and body to osascript as argv', () async {
      final _FakeRunner runner = _FakeRunner();
      final SystemOutcomeNotifier notifier = SystemOutcomeNotifier(
        operatingSystem: 'macos',
        environment: const <String, String>{},
        runProcess: runner.call,
        exists: (String path) => path == '/usr/bin/osascript',
      );

      expect(await notifier.notify(_announcement), isTrue);

      final _Call call = runner.calls.single;
      expect(call.executable, '/usr/bin/osascript');
      // The script itself never contains the text, so nothing in a summary
      // can be read as AppleScript.
      final List<String> script = <String>[
        for (int i = 0; i + 1 < call.arguments.length; i++)
          if (call.arguments[i] == '-e') call.arguments[i + 1],
      ];
      expect(script.join('\n'), isNot(contains(_summary)));
      expect(call.arguments.sublist(call.arguments.length - 2), <String>[
        _announcement.title,
        _summary,
      ]);
    });

    test('Linux uses notify-send with the app name', () async {
      final _FakeRunner runner = _FakeRunner();
      final SystemOutcomeNotifier notifier = SystemOutcomeNotifier(
        operatingSystem: 'linux',
        environment: const <String, String>{'PATH': '/usr/bin'},
        runProcess: runner.call,
        exists: (String path) => path == '/usr/bin/notify-send',
      );

      expect(await notifier.notify(_announcement), isTrue);

      expect(runner.calls.single.executable, '/usr/bin/notify-send');
      expect(runner.calls.single.arguments, <String>[
        '--app-name=$outcomeNotificationAppName',
        '--',
        _announcement.title,
        _summary,
      ]);
    });

    test('without a tool, or where it fails, it answers false', () async {
      final _FakeRunner none = _FakeRunner();
      for (final String os in <String>['linux', 'windows', 'android', 'ios']) {
        expect(
          await SystemOutcomeNotifier(
            operatingSystem: os,
            environment: const <String, String>{},
            runProcess: none.call,
            exists: (String path) => false,
          ).notify(_announcement),
          isFalse,
          reason: os,
        );
      }
      expect(none.calls, isEmpty);

      expect(
        await SystemOutcomeNotifier(
          operatingSystem: 'macos',
          environment: const <String, String>{},
          runProcess: _FakeRunner(exitCode: 1).call,
          exists: (String path) => true,
        ).notify(_announcement),
        isFalse,
      );
    });
  });
}
