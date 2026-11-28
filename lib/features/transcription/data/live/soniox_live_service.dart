import 'dart:convert';
import 'dart:typed_data';

import 'live_ws_service.dart';

/// Soniox real-time STT. The first text frame is the config; audio is binary;
/// the stream ends with an empty **text** frame. Tokens carry their own
/// spacing, so segments are concatenated verbatim. Unverified: the
/// `audio_format` value, the `api_key` field still being required beside the
/// Bearer header, and the keepalive/error frame shapes.
class SonioxLiveService extends LiveWsService {
  SonioxLiveService({
    required super.endpoint,
    super.bearerToken,
    super.model,
    super.language,
    super.connectTimeout,
    super.finishTimeout,
    super.maxBufferedSeconds,
    this.keepAlive = const Duration(seconds: 15),
  });

  final Duration? keepAlive;

  @override
  String get joiner => '';

  @override
  Duration? get keepAliveInterval => keepAlive;

  @override
  Object? get keepAliveMessage =>
      jsonEncode(<String, String>{'type': 'keepalive'});

  @override
  Uri buildUri() => endpoint;

  @override
  Map<String, String> headers() => <String, String>{
    if (bearerToken != null) 'Authorization': 'Bearer $bearerToken',
  };

  @override
  List<Object> openMessages() => <Object>[
    jsonEncode(<String, Object?>{
      if (bearerToken != null) 'api_key': bearerToken,
      'model': (model?.trim().isNotEmpty ?? false)
          ? model!.trim()
          : 'stt-rt-v6',
      'audio_format': 'pcm_s16le',
      'sample_rate': sampleRate,
      'num_channels': 1,
      'language_hints': <String>[
        if (language?.trim().isNotEmpty ?? false) language!.trim() else 'pl',
        if (language?.trim() != 'en') 'en',
      ],
      'enable_endpoint_detection': true,
    }),
  ];

  @override
  List<Object> encodeAudio(Uint8List chunk, LiveSessionState state) => <Object>[
    chunk,
  ];

  @override
  void handle(Map<String, dynamic> message, LiveSessionState state) {
    if (message['error_code'] != null || message['error_message'] != null) {
      state.error = (message['error_message'] ?? message['error_code'])
          .toString();
      return;
    }
    final dynamic tokens = message['tokens'];
    if (tokens is! List) return;
    final StringBuffer partial = StringBuffer();
    final StringBuffer fresh = StringBuffer();
    for (final dynamic token in tokens) {
      if (token is! Map) continue;
      final String text = token['text']?.toString() ?? '';
      if (text == '<end>' || text == '<fin>') continue;
      if (token['is_final'] == true) {
        fresh.write(text);
      } else {
        partial.write(text);
      }
    }
    if (fresh.isNotEmpty) state.committed += fresh.toString();
    state.partial = partial.toString();
  }

  @override
  List<Object> finishMessages(LiveSessionState state) => <Object>[
    jsonEncode(<String, String>{'type': 'finalize'}),
    '',
  ];

  @override
  bool isTerminal(Map<String, dynamic> message, LiveSessionState state) =>
      message['finished'] == true;
}
