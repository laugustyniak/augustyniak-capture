import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:augustyniak_capture/features/processing/data/native_media_processor.dart';
import 'package:augustyniak_capture/features/transcription/data/local_transcription_service.dart';
import 'package:augustyniak_capture/features/transcription/data/whisper_ffi_engine.dart';

/// The on-device half of #90, run on a real Android runtime.
///
/// It is an `integration_test` rather than a `flutter test` because everything
/// it proves needs the device: the NDK-built `.so` packaged in the APK, the
/// MediaCodec decoder behind the platform channel, and the two talking to each
/// other. None of that has a meaningful fake — a fake would only restate the
/// assumption this exists to check.
///
/// Artifacts are pushed to the app's own external files directory beforehand:
///
///   adb push ggml-tiny-q5_1.bin /data/local/tmp/model.bin
///   adb shell 'cat /data/local/tmp/model.bin | run-as ai.augustyniak.capture sh -c "cat > files/model.bin"'
///
/// Piped through `run-as` rather than pushed directly, because neither end of
/// a direct push works: a directory `adb` creates under `/sdcard/Android/data`
/// belongs to `shell` with mode 770 and the app's uid cannot traverse it, and
/// the app's uid cannot read `/data/local/tmp` either. Piping lets each side
/// touch only what it owns.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the packaged engine transcribes a real capture', (
    WidgetTester tester,
  ) async {
    // The app's own internal files directory — `files/` inside the data dir,
    // which is exactly where `run-as` lands.
    final Directory base = await getApplicationSupportDirectory();
    final File model = File('${base.path}/model.bin');
    final File capture = File('${base.path}/capture.m4a');

    expect(
      model.existsSync(),
      isTrue,
      reason: 'push the model into ${base.path} first',
    );
    expect(capture.existsSync(), isTrue, reason: 'push the capture first');

    final WhisperFfiEngine engine = WhisperFfiEngine(
      // The same decoder the shell wires on mobile: MediaCodec through the
      // platform channel, not ffmpeg.
      decoder: const NativeMobileMediaProcessor(),
    );

    expect(
      engine.isAvailable,
      isTrue,
      reason:
          engine.unavailableReason ??
          'the NDK-built library should be loadable from the APK',
    );

    final LocalTranscriptionService service = LocalTranscriptionService(
      engine: engine,
      modelId: 'tiny-q5_1',
      modelPath: (String _) async => model.path,
      language: 'en',
    );

    final String text = await service.transcribe(capture);

    expect(text, isNotEmpty);
    expect(
      text.toLowerCase(),
      contains('country'),
      reason: 'the sample is the JFK line; this is real recognition on-device',
    );
  }, timeout: const Timeout(Duration(minutes: 10)));
}
