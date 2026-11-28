import 'dart:convert';
import 'dart:typed_data';

import 'live_ws_service.dart';

/// ElevenLabs Scribe realtime. Audio goes as base64 inside JSON text frames;
/// results are `partial_transcript` / `committed_transcript`. Unverified: the
/// end-of-stream request (an empty chunk with `commit: true`).
class ElevenLabsLiveService extends LiveWsService {
  ElevenLabsLiveService({
    required super.endpoint,
    super.bearerToken,
    super.model,
    super.language,
    super.connectTimeout,
    super.finishTimeout,
    super.maxBufferedSeconds,
  });

  static const Set<String> _textTypes = <String>{
    'session_started',
    'partial_transcript',
    'committed_transcript',
    'committed_transcript_with_timestamps',
  };

  @override
  Uri buildUri() => endpoint.replace(
    queryParameters: <String, String>{
      'model_id': (model?.trim().isNotEmpty ?? false)
          ? model!.trim()
          : 'scribe_v2_realtime',
      'audio_format': 'pcm_$sampleRate',
      if (language?.trim().isNotEmpty ?? false)
        'language_code': language!.trim(),
      'commit_strategy': 'vad',
      ...endpoint.queryParameters,
    },
  );

  @override
  Map<String, String> headers() => <String, String>{
    'xi-api-key': ?bearerToken,
  };

  @override
  List<Object> openMessages() => const <Object>[];

  String _chunk(String base64Audio, {required bool commit}) =>
      jsonEncode(<String, Object>{
        'message_type': 'input_audio_chunk',
        'audio_base_64': base64Audio,
        'commit': commit,
        'sample_rate': sampleRate,
      });

  @override
  List<Object> encodeAudio(Uint8List chunk, LiveSessionState state) => <Object>[
    _chunk(base64Encode(chunk), commit: false),
  ];

  @override
  void handle(Map<String, dynamic> message, LiveSessionState state) {
    final String type = message['message_type']?.toString() ?? '';
    final String text = message['text']?.toString() ?? '';
    switch (type) {
      case 'partial_transcript':
        state.partial = text;
      case 'committed_transcript':
      case 'committed_transcript_with_timestamps':
        state.commit(text);
        state.partial = '';
      default:
        if (!_textTypes.contains(type) &&
            (message['error'] != null ||
                type.contains('error') ||
                type.contains('quota') ||
                type.contains('limited'))) {
          state.error = (message['error'] ?? type).toString();
        }
    }
  }

  @override
  List<Object> finishMessages(LiveSessionState state) => <Object>[
    _chunk('', commit: true),
  ];

  @override
  bool isTerminal(Map<String, dynamic> message, LiveSessionState state) {
    final String type = message['message_type']?.toString() ?? '';
    return type == 'committed_transcript' ||
        type == 'committed_transcript_with_timestamps';
  }
}
