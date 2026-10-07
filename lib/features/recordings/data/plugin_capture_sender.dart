import 'dart:io';

import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../domain/clipboard_sink.dart';
import 'system_capture_sender.dart';

/// The real [SystemCaptureSender], wired to `url_launcher` and `share_plus`.
///
/// The only place either plugin is touched, so everything in
/// `system_capture_sender.dart` stays testable without a platform channel. Not
/// unit-tested for the same reason; the seams it fills are.
SystemCaptureSender createPluginCaptureSender({
  required ClipboardSink clipboard,
}) {
  return SystemCaptureSender(
    platform: _currentPlatform(),
    clipboard: clipboard,
    // `externalApplication`: a browser tab or the registered app, never an
    // in-app web view that could keep the capture's text.
    launch: (Uri uri) => launchUrl(uri, mode: LaunchMode.externalApplication),
    canLaunch: canLaunchUrl,
    share: ({required String text, String? subject}) async {
      final ShareResult result = await SharePlus.instance.share(
        ShareParams(text: text, subject: subject),
      );
      return switch (result.status) {
        ShareResultStatus.success => ShareStatus.shared,
        ShareResultStatus.dismissed => ShareStatus.dismissed,
        ShareResultStatus.unavailable => ShareStatus.unavailable,
      };
    },
  );
}

SendPlatform _currentPlatform() {
  if (Platform.isAndroid) return SendPlatform.android;
  if (Platform.isIOS) return SendPlatform.ios;
  if (Platform.isMacOS) return SendPlatform.macos;
  if (Platform.isWindows) return SendPlatform.windows;
  return SendPlatform.linux;
}
