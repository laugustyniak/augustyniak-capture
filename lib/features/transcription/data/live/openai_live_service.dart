import 'dart:convert';
import 'dart:typed_data';

import 'live_ws_service.dart';

/// OpenAI Realtime in transcription mode (`gpt-live-transcribe`). 24 kHz PCM,
/// base64 in JSON frames. There is no server VAD here, so the adapter commits
/// the buffer every [commitEvery] of audio; otherwise one turn would last the
/// whole take. Unverified: the `session.update` nesting and Polish support.
class OpenAiLiveService extends LiveWsService {
  OpenAiLiveService({
    required super.endpoint,
    super.bearerToken,
    super.model,
    super.language,
    super.connectTimeout,
    super.finishTimeout,
    super.maxBufferedSeconds,
    this.commitEvery = const Duration(seconds: 15),
  });

  final Duration commitEvery;

  @override
  int get sampleRate => 24000;

  @override
  Uri buildUri() => endpoint.replace(
    queryParameters: <String, String>{
      'intent': 'transcription',
      ...endpoint.queryParameters,
    },
  );

  @override
  Map<String, String> headers() => <String, String>{
    if (bearerToken != null) 'Authorization': 'Bearer $bearerToken',
  };

  @override
  List<Object> openMessages() => <Object>[
    jsonEncode(<String, Object?>{
      'type': 'session.update',
      'session': <String, Object?>{
        'type': 'transcription',
        'audio': <String, Object?>{
          'input': <String, Object?>{
            'format': <String, Object>{'type': 'audio/pcm', 'rate': sampleRate},
            'transcription': <String, Object>{
              'model': (model?.trim().isNotEmpty ?? false)
                  ? model!.trim()
                  : 'gpt-live-transcribe',
              if (language?.trim().isNotEmpty ?? false)
                'language': language!.trim(),
            },
            'turn_detection': null,
          },
        },
      },
    }),
  ];

  static const String _commit = '{"type":"input_audio_buffer.commit"}';

  int _count(LiveSessionState s, String key) => (s.scratch[key] as int?) ?? 0;

  Map<String, String> _partials(LiveSessionState s) =>
      (s.scratch['partials'] ??= <String, String>{}) as Map<String, String>;

  void _syncPartial(LiveSessionState s) =>
      s.partial = _partials(s).values.join(' ');

  @override
  List<Object> encodeAudio(Uint8List chunk, LiveSessionState state) {
    final int uncommitted = _count(state, 'uncommitted') + chunk.length;
    final List<Object> frames = <Object>[
      jsonEncode(<String, String>{
        'type': 'input_audio_buffer.append',
        'audio': base64Encode(chunk),
      }),
    ];
    final int limit = sampleRate * 2 * commitEvery.inSeconds;
    if (uncommitted >= limit) {
      frames.add(_commit);
      state.scratch['uncommitted'] = 0;
      state.scratch['pending'] = _count(state, 'pending') + 1;
    } else {
      state.scratch['uncommitted'] = uncommitted;
    }
    return frames;
  }

  @override
  void handle(Map<String, dynamic> message, LiveSessionState state) {
    switch (message['type']) {
      case 'conversation.item.input_audio_transcription.delta':
        final String id = message['item_id']?.toString() ?? '';
        final Map<String, String> partials = _partials(state);
        partials[id] =
            (partials[id] ?? '') + (message['delta']?.toString() ?? '');
        _syncPartial(state);
      case 'conversation.item.input_audio_transcription.completed':
        _partials(state).remove(message['item_id']?.toString() ?? '');
        state.commit(message['transcript']?.toString() ?? '');
        _syncPartial(state);
        state.scratch['pending'] = _count(state, 'pending') - 1;
      case 'conversation.item.input_audio_transcription.failed':
        _partials(state).remove(message['item_id']?.toString() ?? '');
        _syncPartial(state);
        state.scratch['pending'] = _count(state, 'pending') - 1;
      case 'error':
        final dynamic error = message['error'];
        state.error =
            (error is Map ? error['message'] : error)?.toString() ?? 'error';
    }
  }

  @override
  List<Object> finishMessages(LiveSessionState state) {
    if (_count(state, 'uncommitted') > 0) {
      state.scratch['uncommitted'] = 0;
      state.scratch['pending'] = _count(state, 'pending') + 1;
      return <Object>[_commit];
    }
    return const <Object>[];
  }

  @override
  bool isDrained(LiveSessionState state) => _count(state, 'pending') <= 0;

  @override
  bool isTerminal(Map<String, dynamic> message, LiveSessionState state) {
    final Object? type = message['type'];
    return (type == 'conversation.item.input_audio_transcription.completed' ||
            type == 'conversation.item.input_audio_transcription.failed') &&
        _count(state, 'pending') <= 0;
  }
}
