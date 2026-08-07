import 'package:flutter/services.dart';

import '../domain/capture_session.dart';

/// Android's microphone foreground service, over a method channel.
///
/// The Kotlin half is `CaptureForegroundService`; this only starts and stops
/// it. Nothing is returned because there is nothing to report — the service
/// either holds the exemption or it does not, and the recording is the same
/// recording either way.
///
/// **iOS needs no counterpart.** `record_ios` already sets the audio session to
/// `.playAndRecord` and activates it, so the whole of background recording
/// there is the `UIBackgroundModes: audio` key in `Info.plist`. A channel with
/// nothing to say would be one more thing to keep working.
class ForegroundCaptureSession implements CaptureSession {
  const ForegroundCaptureSession();

  static const MethodChannel _channel = MethodChannel(
    'ai.augustyniak.capture/capture_session',
  );

  @override
  Future<void> begin() => _channel.invokeMethod<void>('begin');

  @override
  Future<void> end() => _channel.invokeMethod<void>('end');
}
