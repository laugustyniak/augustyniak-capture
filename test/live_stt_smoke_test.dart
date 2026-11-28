import 'dart:io';
import 'dart:typed_data';

import 'package:augustyniak_capture/features/settings/domain/provider_profile.dart';
import 'package:augustyniak_capture/features/transcription/data/live/live_provider_factory.dart';
import 'package:augustyniak_capture/features/transcription/domain/live_transcription.dart';
import 'package:flutter_test/flutter_test.dart';

/// Opt-in: talks to the real live-dictation providers, so it is skipped unless
/// a key is in the environment. It is how the wire details marked unverified in
/// `docs/architecture/transcription.md#live-dictation` get confirmed.
///
///     LIVE_STT_SAMPLE_WAV=/path/speech.wav LIVE_STT_DEEPGRAM_KEY=… \
///       flutter test test/live_stt_smoke_test.dart
///
/// The sample must be 16-bit mono PCM WAV, at 16 kHz (24 kHz for OpenAI). The
/// repository has no speech fixture, and the sounds under `assets/` are not
/// speech.
void main() {
  final Map<String, String> env = Platform.environment;
  final String? samplePath = env['LIVE_STT_SAMPLE_WAV'];

  const Map<String, LiveProvider> providers = <String, LiveProvider>{
    'DEEPGRAM': LiveProvider.deepgram,
    'SONIOX': LiveProvider.soniox,
    'ELEVENLABS': LiveProvider.elevenlabs,
    'OPENAI': LiveProvider.openai,
  };

  for (final MapEntry<String, LiveProvider> entry in providers.entries) {
    final String? key = env['LIVE_STT_${entry.key}_KEY'];
    final String? skip = key == null || key.isEmpty
        ? 'set LIVE_STT_${entry.key}_KEY to run'
        : samplePath == null || !File(samplePath).existsSync()
        ? 'set LIVE_STT_SAMPLE_WAV to a speech WAV to run'
        : null;

    test(
      '${entry.key} streams a sample and finishes with text',
      () async {
        final ProviderPreset preset = ProviderPreset.all.firstWhere(
          (ProviderPreset p) =>
              p.kind == ProfileKind.liveTranscription &&
              liveProviderForHost(Uri.parse(p.endpoint).host) == entry.value,
        );
        final LiveTranscriptionService service = buildLiveTranscriptionService(
          endpoint: Uri.parse(preset.endpoint),
          bearerToken: key,
          model: preset.model,
          language: preset.language,
        );
        expect(service.isAvailable, isTrue, reason: 'adapter for ${entry.key}');

        final Uint8List pcm = _pcmOf(File(samplePath!).readAsBytesSync());
        final int chunkBytes = service.sampleRate * 2 ~/ 10;
        final LiveTranscriptionSession session = service.start();
        try {
          for (int i = 0; i < pcm.length; i += chunkBytes) {
            final int end = i + chunkBytes < pcm.length
                ? i + chunkBytes
                : pcm.length;
            session.addAudio(Uint8List.sublistView(pcm, i, end));
            // Four times real time: the provider sees a stream, not a burst.
            await Future<void>.delayed(const Duration(milliseconds: 25));
          }
          final String text = await session.finish();
          expect(
            text.trim(),
            isNotEmpty,
            reason: '${entry.key} finished cleanly but returned no text',
          );
        } finally {
          await session.cancel();
        }
      },
      skip: skip,
      timeout: const Timeout(Duration(seconds: 90)),
    );
  }
}

/// The `data` chunk of a PCM WAV; the whole input if no chunk is found.
Uint8List _pcmOf(Uint8List wav) {
  final ByteData view = ByteData.sublistView(wav);
  int offset = 12;
  while (offset + 8 <= wav.length) {
    final String id = String.fromCharCodes(wav.sublist(offset, offset + 4));
    final int size = view.getUint32(offset + 4, Endian.little);
    if (id == 'data') {
      final int end = offset + 8 + size;
      return Uint8List.sublistView(
        wav,
        offset + 8,
        end > wav.length ? wav.length : end,
      );
    }
    offset += 8 + size + (size.isOdd ? 1 : 0);
  }
  return wav;
}
