import 'dart:convert';
import 'dart:math' as math;
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

  /// Item ids in the order the server committed them to the buffer.
  List<String> _order(LiveSessionState s) =>
      (s.scratch['order'] ??= <String>[]) as List<String>;

  /// Finished items: id to transcript (empty for a failed one).
  Map<String, String> _done(LiveSessionState s) =>
      (s.scratch['done'] ??= <String, String>{}) as Map<String, String>;

  /// Committed text is released in buffer order, never in arrival order: a
  /// short item can finish before the long one before it. An item waiting for
  /// a predecessor is shown as partial until it can be released.
  void _rebuild(LiveSessionState s) {
    final List<String> order = _order(s);
    final Map<String, String> done = _done(s);
    final Map<String, String> partials = _partials(s);
    s.committed = '';
    int i = 0;
    while (i < order.length && done.containsKey(order[i])) {
      s.commit(done[order[i]]!);
      i++;
    }
    final List<String> tail = <String>[
      for (int j = i; j < order.length; j++)
        done[order[j]] ?? partials[order[j]] ?? '',
      for (final MapEntry<String, String> e in partials.entries)
        if (!order.contains(e.key)) e.value,
    ];
    s.partial = tail.where((String t) => t.isNotEmpty).join(' ');
  }

  void _finishItem(LiveSessionState s, Map<String, dynamic> message, String t) {
    final String id = message['item_id']?.toString() ?? '';
    _partials(s).remove(id);
    final List<String> order = _order(s);
    if (!order.contains(id)) order.add(id);
    _done(s)[id] = t;
    s.scratch['pending'] = math.max(0, _count(s, 'pending') - 1);
    _rebuild(s);
  }

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
        _rebuild(state);
      case 'input_audio_buffer.committed':
        final String id = message['item_id']?.toString() ?? '';
        final List<String> order = _order(state);
        if (id.isEmpty || order.contains(id)) break;
        final int after = order.indexOf(
          message['previous_item_id']?.toString() ?? '',
        );
        order.insert(after < 0 ? order.length : after + 1, id);
      case 'conversation.item.input_audio_transcription.completed':
        _finishItem(state, message, message['transcript']?.toString() ?? '');
      case 'conversation.item.input_audio_transcription.failed':
        // A segment without text is a hole: the live text must not be vouched
        // for, so `finish()` throws and the batch pipeline runs on the WAV.
        state.incomplete = 'a segment could not be transcribed';
        _finishItem(state, message, '');
      case 'error':
        final dynamic error = message['error'];
        state.error =
            (error is Map ? error['message'] : error)?.toString() ?? 'error';
    }
  }

  @override
  List<Object> finishMessages(LiveSessionState state) {
    // The server rejects a commit of under 100 ms of audio, and that error
    // would discard text that is otherwise complete. The sliver is dropped.
    if (_count(state, 'uncommitted') >= sampleRate * 2 ~/ 10) {
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
