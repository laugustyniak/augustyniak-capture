import 'dart:async';
import 'dart:io';

import 'package:augustyniak_capture/features/auth/domain/auth_redirect.dart';
import 'package:augustyniak_capture/features/logs/domain/log_event.dart';
import 'package:augustyniak_capture/features/shortcuts/domain/shortcut_action.dart';
import 'package:augustyniak_capture/features/shortcuts/domain/shortcut_link.dart';
import 'package:augustyniak_capture/features/shortcuts/domain/shortcut_link_source.dart';
import 'package:augustyniak_capture/features/shortcuts/presentation/shortcut_link_dispatcher.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeSource implements ShortcutLinkSource {
  final StreamController<Uri> controller = StreamController<Uri>.broadcast();

  @override
  Stream<Uri> get links => controller.stream;
}

class _RecordingLog implements LogSink {
  final List<(String, LogLevel)> lines = <(String, LogLevel)>[];

  @override
  void log(
    String message, {
    LogLevel level = LogLevel.info,
    String? recordingId,
  }) {
    lines.add((message, level));
  }
}

void main() {
  group('ShortcutLink', () {
    test('every action round-trips through its URL', () {
      for (final ShortcutAction action in ShortcutAction.values) {
        final Uri uri = ShortcutLink.forAction(action);
        expect(
          uri.toString(),
          'ai.augustyniak.capture://shortcut/${action.name}',
        );
        expect(ShortcutLink.isShortcut(uri), isTrue);
        expect(ShortcutLink.actionOf(uri), action);
      }
    });

    test('an unknown action is a shortcut URL with no action', () {
      final Uri uri = Uri.parse(
        'ai.augustyniak.capture://shortcut/launchRocket',
      );
      expect(ShortcutLink.isShortcut(uri), isTrue);
      expect(ShortcutLink.actionOf(uri), isNull);
    });

    test('the OAuth callback and foreign schemes are not shortcuts', () {
      for (final Uri uri in <Uri>[
        AuthRedirect.native,
        Uri.parse('ai.augustyniak.capture://login-callback/?code=abc'),
        Uri.parse('https://example.com/shortcut/toggleRecording'),
        Uri.parse('other.app://shortcut/toggleRecording'),
      ]) {
        expect(ShortcutLink.isShortcut(uri), isFalse, reason: '$uri');
        expect(ShortcutLink.actionOf(uri), isNull, reason: '$uri');
      }
    });

    test('a trailing slash still names the action', () {
      expect(
        ShortcutLink.actionOf(
          Uri.parse('ai.augustyniak.capture://shortcut/newTextNote/'),
        ),
        ShortcutAction.newTextNote,
      );
    });
  });

  group('ShortcutLinkDispatcher', () {
    late _FakeSource source;
    late _RecordingLog log;
    late List<ShortcutAction> handled;
    late ShortcutLinkDispatcher dispatcher;

    ShortcutLinkDispatcher build({
      List<String> launchArguments = const <String>[],
    }) => ShortcutLinkDispatcher(
      source: source,
      handle: (ShortcutAction action) async => handled.add(action),
      launchArguments: launchArguments,
      logSink: log,
    );

    setUp(() {
      source = _FakeSource();
      log = _RecordingLog();
      handled = <ShortcutAction>[];
    });

    tearDown(() async {
      await dispatcher.dispose();
      await source.controller.close();
    });

    test('a link received while running reaches the coordinator', () async {
      dispatcher = build()..start();
      await dispatcher.markReady();

      source.controller.add(
        ShortcutLink.forAction(ShortcutAction.toggleRecording),
      );
      source.controller.add(
        ShortcutLink.forAction(ShortcutAction.toggleRecording),
      );
      await pumpEventQueue();

      // Two presses, two toggles: a start and then a stop.
      expect(handled, <ShortcutAction>[
        ShortcutAction.toggleRecording,
        ShortcutAction.toggleRecording,
      ]);
    });

    test('links arriving before the app has loaded wait for it', () async {
      dispatcher = build()..start();

      source.controller.add(ShortcutLink.forAction(ShortcutAction.newTextNote));
      await pumpEventQueue();
      expect(handled, isEmpty);

      await dispatcher.markReady();
      expect(handled, <ShortcutAction>[ShortcutAction.newTextNote]);
    });

    test('a cold start with a shortcut URL runs it once loaded', () async {
      dispatcher = build(
        launchArguments: <String>[
          'ai.augustyniak.capture://shortcut/toggleRecording',
        ],
      )..start();
      await pumpEventQueue();
      expect(handled, isEmpty);

      await dispatcher.markReady();
      expect(handled, <ShortcutAction>[ShortcutAction.toggleRecording]);

      // Marking ready again must not replay the launch action.
      await dispatcher.markReady();
      expect(handled, <ShortcutAction>[ShortcutAction.toggleRecording]);
    });

    test('launch arguments that are not shortcut URLs are ignored', () async {
      dispatcher = build(
        launchArguments: <String>[
          '--verbose',
          AuthRedirect.native.toString(),
          'not a uri at all %%',
        ],
      )..start();
      await dispatcher.markReady();

      expect(handled, isEmpty);
      expect(log.lines, isEmpty);
    });

    test('an unknown action does nothing and is logged', () async {
      dispatcher = build()..start();
      await dispatcher.markReady();

      source.controller.add(
        Uri.parse('ai.augustyniak.capture://shortcut/launchRocket'),
      );
      await pumpEventQueue();

      expect(handled, isEmpty);
      expect(log.lines, hasLength(1));
      expect(log.lines.single.$1, contains('launchRocket'));
      expect(log.lines.single.$2, LogLevel.warn);
    });

    test('the OAuth callback is left alone', () async {
      dispatcher = build()..start();
      await dispatcher.markReady();

      source.controller.add(
        Uri.parse('ai.augustyniak.capture://login-callback/?code=abc'),
      );
      await pumpEventQueue();

      expect(handled, isEmpty);
      expect(log.lines, isEmpty);
    });

    test('a failing action is logged, not thrown', () async {
      dispatcher = ShortcutLinkDispatcher(
        source: source,
        handle: (ShortcutAction action) async => throw StateError('boom'),
        logSink: log,
      )..start();
      await dispatcher.markReady();

      source.controller.add(ShortcutLink.forAction(ShortcutAction.showWindow));
      await pumpEventQueue();

      expect(log.lines.single.$2, LogLevel.error);
      expect(log.lines.single.$1, contains('boom'));
    });

    test('nothing is dispatched after dispose', () async {
      dispatcher = build()..start();
      await dispatcher.markReady();
      await dispatcher.dispose();

      source.controller.add(ShortcutLink.forAction(ShortcutAction.showWindow));
      await pumpEventQueue();

      expect(handled, isEmpty);
    });
  });

  group('Linux runner', () {
    final String runner = File(
      'linux/runner/my_application.cc',
    ).readAsStringSync();

    test('a shortcut URL sent to a running instance does not activate it', () {
      // `activate` ends in `gtk_window_present`, which would raise the window
      // before a recording starts — the one thing toggleRecording must not do.
      expect(runner, contains('"ai.augustyniak.capture://shortcut/"'));
      expect(runner, contains('g_application_get_is_remote'));
      expect(
        RegExp(
          r'if \(!\(is_remote && has_shortcut\)\)\s*\{?\s*g_application_activate',
        ).hasMatch(runner),
        isTrue,
      );
    });

    test('a cold-start shortcut URL is delivered once, not twice', () {
      // It reaches Dart as an entrypoint argument; leaving it in the command
      // line as well would replay it through app_links and toggle twice.
      expect(runner, contains('strip_shortcut_arguments'));
    });
  });
}
