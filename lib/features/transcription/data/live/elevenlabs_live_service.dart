import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'live_ws_service.dart';

/// ElevenLabs Scribe realtime. Audio goes as base64 inside JSON text frames;
/// results are `partial_transcript` / `committed_transcript`. Commits are
/// **manual**: the adapter commits every [commitEvery] of audio and once at the
/// end, and counts the answers, so the end is known when every commit it sent
/// was answered. (With `commit_strategy=vad` a commit the server made on its own
/// is indistinguishable from the answer to ours.) Unverified: the commit-flagged
/// chunks, the end-of-stream request being an empty one, and the minimum audio
/// a commit accepts.
class ElevenLabsLiveService extends LiveWsService {
  ElevenLabsLiveService({
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
      'commit_strategy': 'manual',
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
  List<Object> encodeAudio(Uint8List chunk, LiveSessionState state) {
    final int uncommitted = _count(state, 'uncommitted') + chunk.length;
    final bool commit = uncommitted >= sampleRate * 2 * commitEvery.inSeconds;
    state.scratch['uncommitted'] = commit ? 0 : uncommitted;
    if (commit) state.scratch['pending'] = _count(state, 'pending') + 1;
    return <Object>[_chunk(base64Encode(chunk), commit: commit)];
  }

  int _count(LiveSessionState s, String key) => (s.scratch[key] as int?) ?? 0;

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
        // Clamped: an answer nobody asked for must not cancel a commit that is
        // still owed.
        state.scratch['pending'] = math.max(0, _count(state, 'pending') - 1);
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
  List<Object> finishMessages(LiveSessionState state) {
    // Under 100 ms (or nothing) uncommitted: nothing worth a commit, which
    // could only draw an error. Commits already in flight are still awaited.
    if (_count(state, 'uncommitted') < sampleRate * 2 ~/ 10) {
      return const <Object>[];
    }
    state.scratch['uncommitted'] = 0;
    state.scratch['pending'] = _count(state, 'pending') + 1;
    return <Object>[_chunk('', commit: true)];
  }

  @override
  bool isDrained(LiveSessionState state) => _count(state, 'pending') <= 0;

  @override
  bool isTerminal(Map<String, dynamic> message, LiveSessionState state) {
    final String type = message['message_type']?.toString() ?? '';
    return (type == 'committed_transcript' ||
            type == 'committed_transcript_with_timestamps') &&
        _count(state, 'pending') <= 0;
  }
}
