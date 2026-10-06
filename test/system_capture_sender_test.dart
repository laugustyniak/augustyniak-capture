import 'package:augustyniak_capture/features/recordings/data/system_capture_sender.dart';
import 'package:augustyniak_capture/features/recordings/domain/assistant_target.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_router.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_sender.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/clipboard_sink.dart';
import 'package:augustyniak_capture/features/recordings/domain/route_record.dart';
import 'package:flutter_test/flutter_test.dart';

class _Clipboard implements ClipboardSink {
  final List<String> copied = <String>[];
  final List<String> events;
  _Clipboard(this.events);

  @override
  Future<void> copy(String text) async {
    events.add('copy');
    copied.add(text);
  }
}

class _Rig {
  _Rig({
    this.platform = SendPlatform.linux,
    this.launchResult = true,
    this.canLaunchClaude = true,
    this.shareStatus = ShareStatus.shared,
  }) {
    clipboard = _Clipboard(events);
    sender = SystemCaptureSender(
      platform: platform,
      clipboard: clipboard,
      launch: (Uri uri) async {
        events.add('launch');
        launched.add(uri);
        return launchResult;
      },
      canLaunch: (Uri uri) async {
        probed.add(uri);
        return canLaunchClaude;
      },
      share: ({required String text, String? subject}) async {
        events.add('share');
        shared.add((text: text, subject: subject));
        return shareStatus;
      },
      now: () => DateTime.utc(2026, 10, 6, 12),
    );
  }

  final SendPlatform platform;
  final bool launchResult;
  final bool canLaunchClaude;
  final ShareStatus shareStatus;
  final List<String> events = <String>[];
  final List<Uri> launched = <Uri>[];
  final List<Uri> probed = <Uri>[];
  final List<({String text, String? subject})> shared =
      <({String text, String? subject})>[];
  late final _Clipboard clipboard;
  late final SystemCaptureSender sender;
}

RoutedCapture _capture() => RoutedCapture(
  id: 'r1',
  projectId: null,
  title: 'Idea',
  body: 'body',
  capturedAt: DateTime.utc(2026, 10, 6),
  type: CaptureType.text,
);

void main() {
  group('send', () {
    test('a prefilled web target launches the URL and does not copy', () async {
      final _Rig rig = _Rig();

      final SendOutcome? outcome = await rig.sender.send(
        _capture(),
        const AssistantSendTarget(AssistantTarget.chatgpt),
        'hello & goodbye',
      );

      expect(
        rig.launched.single.toString(),
        'https://chatgpt.com/?q=hello%20%26%20goodbye',
      );
      expect(rig.clipboard.copied, isEmpty);
      expect(outcome!.copiedToClipboard, isFalse);
      expect(outcome.record.kind, RouteKind.assistant);
      expect(outcome.record.target, 'ChatGPT · web');
      expect(outcome.record.at, DateTime.utc(2026, 10, 6, 12));
    });

    test('Gemini copies first, then opens the bare page', () async {
      final _Rig rig = _Rig();

      final SendOutcome? outcome = await rig.sender.send(
        _capture(),
        const AssistantSendTarget(AssistantTarget.gemini),
        'the prompt',
      );

      expect(rig.events, <String>['copy', 'launch']);
      expect(rig.clipboard.copied.single, 'the prompt');
      expect(rig.launched.single.toString(), 'https://gemini.google.com/app');
      expect(outcome!.copiedToClipboard, isTrue);
    });

    test('an over-long prompt is copied whole, never truncated', () async {
      final _Rig rig = _Rig();
      final String long = 'ż' * 1500;

      final SendOutcome? outcome = await rig.sender.send(
        _capture(),
        const AssistantSendTarget(AssistantTarget.perplexity),
        long,
      );

      expect(rig.clipboard.copied.single, long);
      expect(rig.launched.single.hasQuery, isFalse);
      expect(outcome!.copiedToClipboard, isTrue);
    });

    test('Claude Desktop records its own target string', () async {
      final _Rig rig = _Rig();

      final SendOutcome? outcome = await rig.sender.send(
        _capture(),
        const AssistantSendTarget(AssistantTarget.claudeDesktop),
        'hi',
      );

      expect(rig.launched.single.scheme, 'claude');
      expect(outcome!.record.target, 'Claude Desktop');
    });

    test('a launch that answers false throws, naming the target', () async {
      final _Rig rig = _Rig(launchResult: false);

      await expectLater(
        rig.sender.send(
          _capture(),
          const AssistantSendTarget(AssistantTarget.claudeWeb),
          'hi',
        ),
        throwsA(
          isA<AssistantUnavailableException>().having(
            (AssistantUnavailableException e) => e.toString(),
            'message',
            contains('Claude'),
          ),
        ),
      );
    });

    test('share hands the prompt and title to the share function', () async {
      final _Rig rig = _Rig(platform: SendPlatform.android);

      final SendOutcome? outcome = await rig.sender.send(
        _capture(),
        const ShareSendTarget(),
        'hi',
      );

      expect(rig.shared.single, (text: 'hi', subject: 'Idea'));
      expect(outcome!.record.kind, RouteKind.assistant);
      expect(outcome.record.target, 'share');
      expect(outcome.copiedToClipboard, isFalse);
    });

    test('an unconfirmed share still counts as opened', () async {
      final _Rig rig = _Rig(shareStatus: ShareStatus.unavailable);

      final SendOutcome? outcome = await rig.sender.send(
        _capture(),
        const ShareSendTarget(),
        'hi',
      );

      expect(outcome, isNotNull);
    });

    test('a dismissed share answers null so nothing is recorded', () async {
      final _Rig rig = _Rig(shareStatus: ShareStatus.dismissed);

      final SendOutcome? outcome = await rig.sender.send(
        _capture(),
        const ShareSendTarget(),
        'hi',
      );

      expect(outcome, isNull);
    });

    test('copy writes the clipboard and records clipboard', () async {
      final _Rig rig = _Rig();

      final SendOutcome? outcome = await rig.sender.send(
        _capture(),
        const CopySendTarget(),
        'text',
      );

      expect(rig.clipboard.copied.single, 'text');
      expect(rig.launched, isEmpty);
      expect(outcome!.record.target, 'clipboard');
      expect(outcome.copiedToClipboard, isTrue);
    });
  });

  group('availableTargets', () {
    List<SendTarget> web() => <SendTarget>[
      const AssistantSendTarget(AssistantTarget.claudeWeb),
      const AssistantSendTarget(AssistantTarget.chatgpt),
      const AssistantSendTarget(AssistantTarget.perplexity),
      const AssistantSendTarget(AssistantTarget.gemini),
    ];

    test(
      'Linux has Claude Desktop when a handler answers, web and copy',
      () async {
        final _Rig rig = _Rig();

        final List<SendTarget> targets = await rig.sender.availableTargets();

        expect(targets, <SendTarget>[
          const AssistantSendTarget(AssistantTarget.claudeDesktop),
          ...web(),
          const CopySendTarget(),
        ]);
        expect(rig.probed.single.toString(), 'claude://claude.ai/new');
      },
    );

    test('Claude Desktop is left out when nothing handles claude://', () async {
      final _Rig rig = _Rig(canLaunchClaude: false);

      expect(await rig.sender.availableTargets(), <SendTarget>[
        ...web(),
        const CopySendTarget(),
      ]);
    });

    test('Windows has no share, Linux has no share', () async {
      for (final SendPlatform p in <SendPlatform>[
        SendPlatform.linux,
        SendPlatform.windows,
      ]) {
        final List<SendTarget> targets = await _Rig(
          platform: p,
        ).sender.availableTargets();
        expect(targets.whereType<ShareSendTarget>(), isEmpty, reason: '$p');
      }
    });

    test('macOS has Claude Desktop and share, share after web', () async {
      final List<SendTarget> targets = await _Rig(
        platform: SendPlatform.macos,
      ).sender.availableTargets();

      expect(targets, <SendTarget>[
        const AssistantSendTarget(AssistantTarget.claudeDesktop),
        ...web(),
        const ShareSendTarget(),
        const CopySendTarget(),
      ]);
    });

    test(
      'Android lists share first and never probes for Claude Desktop',
      () async {
        final _Rig rig = _Rig(platform: SendPlatform.android);

        expect(await rig.sender.availableTargets(), <SendTarget>[
          const ShareSendTarget(),
          ...web(),
          const CopySendTarget(),
        ]);
        expect(rig.probed, isEmpty);
      },
    );

    test('iOS has share but no Claude Desktop', () async {
      final List<SendTarget> targets = await _Rig(
        platform: SendPlatform.ios,
      ).sender.availableTargets();

      expect(targets.first, isNot(isA<ShareSendTarget>()));
      expect(targets, contains(const ShareSendTarget()));
      expect(
        targets,
        isNot(
          contains(const AssistantSendTarget(AssistantTarget.claudeDesktop)),
        ),
      );
    });
  });

  test('the disabled sender throws at use and offers only nothing', () async {
    const DisabledCaptureSender sender = DisabledCaptureSender();

    expect(await sender.availableTargets(), isEmpty);
    await expectLater(
      sender.send(_capture(), const CopySendTarget(), 'x'),
      throwsA(isA<CaptureSenderUnavailableException>()),
    );
  });
}
