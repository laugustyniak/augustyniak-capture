import 'dart:convert';
import 'dart:typed_data';

import 'live_ws_service.dart';

/// Deepgram `/v1/listen` streaming. Audio is raw PCM in binary frames; results
/// arrive as `Results` with `is_final`. Wire details from Deepgram's docs,
/// 2026-11-28; the KeepAlive frame is unverified.
class DeepgramLiveService extends LiveWsService {
  DeepgramLiveService({
    required super.endpoint,
    super.bearerToken,
    super.model,
    super.language,
    super.connectTimeout,
    super.finishTimeout,
    super.maxBufferedSeconds,
    this.keepAlive = const Duration(seconds: 5),
  });

  final Duration? keepAlive;

  @override
  Duration? get keepAliveInterval => keepAlive;

  /// Deepgram answers `CloseStream` by flushing and closing normally.
  @override
  bool get closeIsTerminal => true;

  @override
  Object? get keepAliveMessage =>
      jsonEncode(<String, String>{'type': 'KeepAlive'});

  @override
  Uri buildUri() => endpoint.replace(
    queryParameters: <String, String>{
      'model': (model?.trim().isNotEmpty ?? false) ? model!.trim() : 'nova-3',
      if (language?.trim().isNotEmpty ?? false) 'language': language!.trim(),
      'encoding': 'linear16',
      'sample_rate': '$sampleRate',
      'channels': '1',
      'interim_results': 'true',
      'punctuate': 'true',
      'smart_format': 'true',
      ...endpoint.queryParameters,
    },
  );

  @override
  Map<String, String> headers() => <String, String>{
    if (bearerToken != null) 'Authorization': 'Token $bearerToken',
  };

  @override
  List<Object> openMessages() => const <Object>[];

  @override
  List<Object> encodeAudio(Uint8List chunk, LiveSessionState state) => <Object>[
    chunk,
  ];

  @override
  void handle(Map<String, dynamic> message, LiveSessionState state) {
    switch (message['type']) {
      case 'Results':
        final dynamic alternatives =
            (message['channel'] as Map?)?['alternatives'];
        final String text =
            (alternatives is List && alternatives.isNotEmpty
                    ? (alternatives.first as Map)['transcript']
                    : null)
                ?.toString() ??
            '';
        if (message['is_final'] == true) {
          state.commit(text);
          state.partial = '';
        } else {
          state.partial = text;
        }
      case 'Error':
        state.error = (message['description'] ?? message['message'] ?? 'error')
            .toString();
    }
  }

  @override
  List<Object> finishMessages(LiveSessionState state) => <Object>[
    jsonEncode(<String, String>{'type': 'Finalize'}),
    jsonEncode(<String, String>{'type': 'CloseStream'}),
  ];

  @override
  bool isTerminal(Map<String, dynamic> message, LiveSessionState state) =>
      message['type'] == 'Metadata';
}
