import '../../domain/live_transcription.dart';
import 'deepgram_live_service.dart';
import 'elevenlabs_live_service.dart';
import 'live_ws_service.dart';
import 'openai_live_service.dart';
import 'soniox_live_service.dart';

enum LiveProvider { deepgram, soniox, elevenlabs, openai }

/// Which provider speaks at [endpoint], by host. Null for an unknown host.
LiveProvider? liveProviderForHost(String host) {
  final String name = host.toLowerCase();
  bool on(String domain) => name == domain || name.endsWith('.$domain');
  if (on('deepgram.com')) return LiveProvider.deepgram;
  if (on('soniox.com')) return LiveProvider.soniox;
  if (on('elevenlabs.io')) return LiveProvider.elevenlabs;
  if (on('openai.com')) return LiveProvider.openai;
  return null;
}

/// Builds the adapter for [endpoint]. An unknown host degrades to the disabled
/// service rather than guessing a protocol. [provider] overrides the host
/// lookup, which is what lets a test point an adapter at a loopback server.
LiveTranscriptionService buildLiveTranscriptionService({
  required Uri endpoint,
  String? bearerToken,
  String? model,
  String? language,
  LiveProvider? provider,
  Duration finishTimeout = const Duration(seconds: 8),
}) {
  final LiveProvider? which = provider ?? liveProviderForHost(endpoint.host);
  if (which == null) return const DisabledLiveTranscriptionService();
  final LiveWsService Function({
    required Uri endpoint,
    String? bearerToken,
    String? model,
    String? language,
    Duration finishTimeout,
  })
  make = switch (which) {
    LiveProvider.deepgram => DeepgramLiveService.new,
    LiveProvider.soniox => SonioxLiveService.new,
    LiveProvider.elevenlabs => ElevenLabsLiveService.new,
    LiveProvider.openai => OpenAiLiveService.new,
  };
  return make(
    endpoint: endpoint,
    bearerToken: bearerToken,
    model: model,
    language: language,
    finishTimeout: finishTimeout,
  );
}
