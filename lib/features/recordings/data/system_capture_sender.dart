import '../domain/assistant_target.dart';
import '../domain/capture_router.dart';
import '../domain/capture_sender.dart';
import '../domain/clipboard_sink.dart';
import '../domain/route_record.dart';

/// The platforms the sender distinguishes. Injected rather than read from
/// `dart:io` so the per-platform answers are testable on any machine.
enum SendPlatform { android, ios, macos, linux, windows }

/// How a share sheet ended, as far as this app can tell.
enum ShareStatus {
  /// The user picked a destination.
  shared,

  /// The user closed the sheet without choosing.
  dismissed,

  /// The platform cannot say — it opened, and that is all that is known.
  /// Treated as sent: nothing was refused.
  unavailable,
}

/// Opens links, shares text and copies it, through function seams so the suite
/// touches no platform channel. The wiring in `lib/app` supplies `url_launcher`
/// and `share_plus`; mapping `share_plus`'s own status to [ShareStatus] happens
/// there, not here.
class SystemCaptureSender implements CaptureSender {
  SystemCaptureSender({
    required this.platform,
    required this.clipboard,
    required this.launch,
    required this.canLaunch,
    required this.share,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final SendPlatform platform;
  final ClipboardSink clipboard;
  final Future<bool> Function(Uri uri) launch;
  final Future<bool> Function(Uri uri) canLaunch;
  final Future<ShareStatus> Function({required String text, String? subject})
  share;
  final DateTime Function() _now;

  bool get _isDesktop =>
      platform == SendPlatform.macos ||
      platform == SendPlatform.linux ||
      platform == SendPlatform.windows;

  /// Share is a real share sheet only here; on Linux and Windows `share_plus`
  /// falls back to a `mailto:` link, which is not one.
  bool get _hasShare =>
      platform == SendPlatform.android ||
      platform == SendPlatform.ios ||
      platform == SendPlatform.macos;

  static final Uri _claudeProbe = Uri(
    scheme: 'claude',
    host: 'claude.ai',
    path: '/new',
  );

  @override
  Future<List<SendTarget>> availableTargets() async {
    bool desktopClaude = false;
    if (_isDesktop) {
      try {
        desktopClaude = await canLaunch(_claudeProbe);
      } catch (_) {
        desktopClaude = false;
      }
    }
    final bool shareFirst = platform == SendPlatform.android;
    return <SendTarget>[
      if (shareFirst) const ShareSendTarget(),
      if (desktopClaude)
        const AssistantSendTarget(AssistantTarget.claudeDesktop),
      for (final AssistantTarget target in AssistantTarget.values)
        if (target.isWeb) AssistantSendTarget(target),
      if (_hasShare && !shareFirst) const ShareSendTarget(),
      const CopySendTarget(),
    ];
  }

  @override
  Future<SendOutcome?> send(
    RoutedCapture capture,
    SendTarget target,
    String prompt,
  ) async {
    return switch (target) {
      AssistantSendTarget(:final AssistantTarget target) => _assistant(
        target,
        prompt,
      ),
      ShareSendTarget() => _share(capture, prompt),
      CopySendTarget() => _copy(prompt),
    };
  }

  Future<SendOutcome> _assistant(AssistantTarget target, String prompt) async {
    final AssistantLaunch plan = target.launchFor(prompt);
    // Copy first: once the browser is in front the user is already pasting.
    if (plan.needsClipboard) await clipboard.copy(prompt);
    if (!await launch(plan.uri)) throw AssistantUnavailableException(target);
    return _outcome(target.routeTarget, copied: plan.needsClipboard);
  }

  Future<SendOutcome?> _share(RoutedCapture capture, String prompt) async {
    final String title = capture.title.trim();
    final ShareStatus status = await share(
      text: prompt,
      subject: title.isEmpty ? null : title,
    );
    if (status == ShareStatus.dismissed) return null;
    return _outcome('share', copied: false);
  }

  Future<SendOutcome> _copy(String prompt) async {
    await clipboard.copy(prompt);
    return _outcome('clipboard', copied: true);
  }

  SendOutcome _outcome(String target, {required bool copied}) => SendOutcome(
    record: RouteRecord(at: _now(), kind: RouteKind.assistant, target: target),
    copiedToClipboard: copied,
  );
}
