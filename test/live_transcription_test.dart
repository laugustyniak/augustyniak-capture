import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:augustyniak_capture/features/transcription/data/live/deepgram_live_service.dart';
import 'package:augustyniak_capture/features/transcription/data/live/elevenlabs_live_service.dart';
import 'package:augustyniak_capture/features/transcription/data/live/live_provider_factory.dart';
import 'package:augustyniak_capture/features/transcription/data/live/openai_live_service.dart';
import 'package:augustyniak_capture/features/transcription/data/live/soniox_live_service.dart';
import 'package:augustyniak_capture/features/transcription/domain/live_transcription.dart';
import 'package:flutter_test/flutter_test.dart';

/// A loopback WebSocket server that records what the adapter sends and lets a
/// test script the provider's replies. No network leaves the machine.
class _Server {
  _Server._(this._http);

  final HttpServer _http;
  final List<Object> received = <Object>[];
  final Completer<void> _connected = Completer<void>();
  WebSocket? socket;
  HttpRequest? request;

  /// Called for every client frame; reply through [socket].
  void Function(_Server server, Object frame)? onFrame;

  /// When set, the upgrade waits for it: the client is still "connecting".
  Completer<void>? gate;

  static Future<_Server> start() async {
    final HttpServer http = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final _Server server = _Server._(http);
    http.listen((HttpRequest request) async {
      server.request = request;
      final Completer<void>? gate = server.gate;
      if (gate != null) await gate.future;
      final WebSocket ws = await WebSocketTransformer.upgrade(request);
      server.socket = ws;
      ws.listen(
        (dynamic frame) {
          server.received.add(frame as Object);
          server.onFrame?.call(server, frame);
        },
        onError: (Object _) {},
        onDone: () {},
      );
      if (!server._connected.isCompleted) server._connected.complete();
    });
    return server;
  }

  Uri get uri => Uri.parse('ws://127.0.0.1:${_http.port}/stream');

  Future<void> get connected => _connected.future;

  void send(Map<String, Object?> message) => socket!.add(jsonEncode(message));

  List<String> get texts => received.whereType<String>().toList();
  List<List<int>> get binaries =>
      received.where((Object f) => f is! String).cast<List<int>>().toList();

  Future<void> close() async {
    await socket?.close();
    await _http.close(force: true);
  }
}

/// Polls rather than sleeping: a wait encodes a guess about machine load.
Future<void> _until(
  bool Function() condition, {
  String what = 'condition',
  Duration timeout = const Duration(seconds: 10),
}) async {
  final DateTime end = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(end)) throw StateError('timed out: $what');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Uint8List _pcm(int bytes, [int fill = 1]) =>
    Uint8List.fromList(List<int>.filled(bytes, fill));

Map<String, dynamic> _json(String text) =>
    jsonDecode(text) as Map<String, dynamic>;

void main() {
  late _Server server;
  late List<LiveTranscriptionSession> sessions;

  setUp(() async {
    server = await _Server.start();
    sessions = <LiveTranscriptionSession>[];
  });

  tearDown(() async {
    for (final LiveTranscriptionSession s in sessions) {
      await s.cancel();
    }
    await server.close();
  });

  LiveTranscriptionSession open(LiveTranscriptionService service) {
    final LiveTranscriptionSession session = service.start();
    sessions.add(session);
    return session;
  }

  group('the disabled seam', () {
    test('is unavailable and refuses to start', () {
      const DisabledLiveTranscriptionService service =
          DisabledLiveTranscriptionService();
      expect(service.isAvailable, isFalse);
      expect(service.start, throwsStateError);
    });
  });

  group('Deepgram', () {
    DeepgramLiveService service({
      Duration finishTimeout = const Duration(seconds: 5),
      Duration? keepAlive,
      int maxBufferedSeconds = 30,
    }) => DeepgramLiveService(
      endpoint: server.uri,
      bearerToken: 'dg-key',
      language: 'pl',
      finishTimeout: finishTimeout,
      keepAlive: keepAlive,
      maxBufferedSeconds: maxBufferedSeconds,
    );

    Map<String, Object?> results(String text, {required bool isFinal}) =>
        <String, Object?>{
          'type': 'Results',
          'is_final': isFinal,
          'channel': <String, Object?>{
            'alternatives': <Object>[
              <String, Object?>{'transcript': text},
            ],
          },
        };

    test('sends the token header and the query parameters', () async {
      open(service());
      await server.connected;
      final HttpRequest request = server.request!;
      expect(request.headers.value('authorization'), 'Token dg-key');
      final Map<String, String> q = request.uri.queryParameters;
      expect(q['model'], 'nova-3');
      expect(q['language'], 'pl');
      expect(q['encoding'], 'linear16');
      expect(q['sample_rate'], '16000');
      expect(q['interim_results'], 'true');
    });

    test('audio goes out as binary frames of the raw PCM', () async {
      final LiveTranscriptionSession session = open(service());
      await server.connected;
      session.addAudio(_pcm(640, 7));
      await _until(() => server.binaries.isNotEmpty, what: 'audio frame');
      expect(server.binaries.single, _pcm(640, 7));
    });

    test('audio added before the socket opens is flushed in order', () async {
      server.gate = Completer<void>();
      final LiveTranscriptionSession session = open(service());
      session.addAudio(_pcm(10, 1));
      session.addAudio(_pcm(10, 2));
      server.gate!.complete();
      await _until(() => server.binaries.length == 2, what: 'flushed audio');
      expect(server.binaries[0].first, 1);
      expect(server.binaries[1].first, 2);
    });

    test('the pre-connect buffer is bounded and drops the oldest', () async {
      server.gate = Completer<void>();
      // 1 s of 16 kHz mono PCM16 = 32 000 bytes.
      final LiveTranscriptionSession session = open(
        service(maxBufferedSeconds: 1),
      );
      session.addAudio(_pcm(20000, 1));
      session.addAudio(_pcm(20000, 2));
      session.addAudio(_pcm(20000, 3));
      server.gate!.complete();
      await _until(() => server.binaries.length == 1, what: 'flushed audio');
      // 60 000 bytes were offered against a 32 000 byte cap.
      expect(server.binaries.single.first, 3);
    });

    test('interim results replace the partial, finals are committed', () async {
      final LiveTranscriptionSession session = open(service());
      final List<LiveTranscript> seen = <LiveTranscript>[];
      session.updates.listen(seen.add);
      await server.connected;

      server.send(results('dzień do', isFinal: false));
      await _until(
        () => seen.any((LiveTranscript t) => t.partial == 'dzień do'),
      );
      server.send(results('dzień dobry', isFinal: true));
      await _until(
        () => seen.any((LiveTranscript t) => t.committed == 'dzień dobry'),
      );
      expect(seen.last.partial, '');
      server.send(results('świecie', isFinal: true));
      await _until(
        () => seen.any(
          (LiveTranscript t) => t.committed == 'dzień dobry świecie',
        ),
      );
      expect(seen.every((LiveTranscript t) => !t.failed), isTrue);
    });

    test(
      'finish sends Finalize then CloseStream and returns the flushed text',
      () async {
        final LiveTranscriptionSession session = open(service());
        server.onFrame = (_Server s, Object frame) {
          if (frame is String && _json(frame)['type'] == 'CloseStream') {
            s.send(results('ostatnie słowa', isFinal: true));
            s.send(<String, Object?>{'type': 'Metadata'});
          }
        };
        await server.connected;
        session.addAudio(_pcm(64));
        final String text = await session.finish();

        expect(text, 'ostatnie słowa');
        final List<String> types = server.texts
            .map((String t) => _json(t)['type'] as String)
            .toList();
        expect(types, <String>['Finalize', 'CloseStream']);
      },
    );

    test(
      'finish waits for the connection and flushes buffered audio first',
      () async {
        server.gate = Completer<void>();
        final LiveTranscriptionSession session = open(service());
        server.onFrame = (_Server s, Object frame) {
          if (frame is String && _json(frame)['type'] == 'CloseStream') {
            s.send(results('z bufora', isFinal: true));
            s.send(<String, Object?>{'type': 'Metadata'});
          }
        };
        session.addAudio(_pcm(32));
        final Future<String> done = session.finish();
        server.gate!.complete();
        expect(await done, 'z bufora');
        expect(server.binaries, hasLength(1));
      },
    );

    test('finish times out and returns the partial as best effort', () async {
      final LiveTranscriptionSession session = open(
        service(finishTimeout: const Duration(milliseconds: 200)),
      );
      await server.connected;
      server.send(results('pierwsze', isFinal: true));
      server.send(results('drugie', isFinal: false));
      final Completer<void> heard = Completer<void>();
      session.updates.listen((LiveTranscript t) {
        if (t.partial == 'drugie' && !heard.isCompleted) heard.complete();
      });
      await heard.future;
      // The server never answers CloseStream.
      expect(await session.finish(), 'pierwsze drugie');
    });

    test(
      'a server drop mid-stream reports failed and keeps committed text',
      () async {
        final LiveTranscriptionSession session = open(service());
        final List<LiveTranscript> seen = <LiveTranscript>[];
        session.updates.listen(seen.add);
        await server.connected;
        server.send(results('zapisane', isFinal: true));
        await _until(() => seen.isNotEmpty);

        await server.socket!.close(WebSocketStatus.goingAway);
        await _until(() => seen.any((LiveTranscript t) => t.failed));

        final LiveTranscript failed = seen.last;
        expect(failed.failed, isTrue);
        expect(failed.committed, 'zapisane');
        // Audio after the drop is swallowed, never thrown.
        session.addAudio(_pcm(100));
        expect(await session.finish(), 'zapisane');
      },
    );

    test('a drop discards the unfinalised partial, keeps committed', () async {
      final LiveTranscriptionSession session = open(service());
      final List<LiveTranscript> seen = <LiveTranscript>[];
      session.updates.listen(seen.add);
      await server.connected;
      server.send(results('zapisane', isFinal: true));
      server.send(results('niepewne', isFinal: false));
      await _until(
        () => seen.any((LiveTranscript t) => t.partial == 'niepewne'),
      );
      await server.socket!.close(WebSocketStatus.goingAway);
      await _until(() => seen.any((LiveTranscript t) => t.failed));
      expect(seen.last.partial, '');
      expect(await session.finish(), 'zapisane');
    });

    test('a provider Error message ends the session as failed', () async {
      final LiveTranscriptionSession session = open(service());
      final List<LiveTranscript> seen = <LiveTranscript>[];
      session.updates.listen(seen.add);
      await server.connected;
      server.send(<String, Object?>{'type': 'Error', 'description': 'bad key'});
      await _until(() => seen.any((LiveTranscript t) => t.failed));
    });

    test(
      'a refused connection is a failed session, not an exception',
      () async {
        final DeepgramLiveService dead = service();
        await server.close();
        final LiveTranscriptionSession session = open(dead);
        final List<LiveTranscript> seen = <LiveTranscript>[];
        session.updates.listen(seen.add);
        await _until(() => seen.any((LiveTranscript t) => t.failed));
        session.addAudio(_pcm(10));
        expect(await session.finish(), '');
        server = await _Server.start();
      },
    );

    test('cancel closes the socket', () async {
      final LiveTranscriptionSession session = open(service());
      await server.connected;
      await session.cancel();
      await _until(() => server.socket!.closeCode != null, what: 'closed');
      expect(server.socket!.closeCode, WebSocketStatus.normalClosure);
    });

    test(
      'cancel before the socket opens closes it as soon as it does',
      () async {
        server.gate = Completer<void>();
        final LiveTranscriptionSession session = open(service());
        await session.cancel();
        server.gate!.complete();
        await server.connected;
        await _until(() => server.socket!.closeCode != null, what: 'closed');
      },
    );

    test('an idle session sends KeepAlive', () async {
      open(service(keepAlive: const Duration(milliseconds: 50)));
      await server.connected;
      await _until(
        () => server.texts.any((String t) => _json(t)['type'] == 'KeepAlive'),
        what: 'keepalive',
      );
    });
  });

  group('Soniox', () {
    SonioxLiveService service() => SonioxLiveService(
      endpoint: server.uri,
      bearerToken: 'so-key',
      finishTimeout: const Duration(seconds: 5),
    );

    test('sends the bearer header and the config as the first frame', () async {
      open(service());
      await server.connected;
      await _until(() => server.received.isNotEmpty, what: 'config');
      expect(server.request!.headers.value('authorization'), 'Bearer so-key');
      final Map<String, dynamic> config = _json(server.texts.first);
      expect(config['api_key'], 'so-key');
      expect(config['model'], 'stt-rt-v6');
      expect(config['audio_format'], 'pcm_s16le');
      expect(config['sample_rate'], 16000);
      expect(config['num_channels'], 1);
      expect(config['language_hints'], <String>['pl', 'en']);
    });

    test('audio is binary and follows the config', () async {
      final LiveTranscriptionSession session = open(service());
      await server.connected;
      session.addAudio(_pcm(320, 9));
      await _until(() => server.received.length == 2, what: 'audio');
      expect(server.received.first, isA<String>());
      expect(server.binaries.single, _pcm(320, 9));
    });

    test(
      'final tokens concatenate verbatim, partial is replaced, specials drop',
      () async {
        final LiveTranscriptionSession session = open(service());
        final List<LiveTranscript> seen = <LiveTranscript>[];
        session.updates.listen(seen.add);
        await server.connected;

        server.send(<String, Object?>{
          'tokens': <Object>[
            <String, Object?>{'text': 'Dzień', 'is_final': true},
            <String, Object?>{'text': ' do', 'is_final': false},
          ],
        });
        await _until(
          () => seen.any(
            (LiveTranscript t) => t.committed == 'Dzień' && t.partial == ' do',
          ),
        );
        server.send(<String, Object?>{
          'tokens': <Object>[
            <String, Object?>{'text': ' dobry', 'is_final': true},
            <String, Object?>{'text': '<end>', 'is_final': true},
          ],
        });
        await _until(
          () => seen.any(
            (LiveTranscript t) =>
                t.committed == 'Dzień dobry' && t.partial == '',
          ),
        );
      },
    );

    test('finish sends finalize then an empty text frame', () async {
      final LiveTranscriptionSession session = open(service());
      server.onFrame = (_Server s, Object frame) {
        if (frame is String && frame.isEmpty) {
          s.send(<String, Object?>{
            'tokens': <Object>[
              <String, Object?>{'text': 'Koniec', 'is_final': true},
            ],
            'finished': true,
          });
        }
      };
      await server.connected;
      expect(await session.finish(), 'Koniec');
      // config, finalize, empty end-of-stream frame.
      expect(server.texts, hasLength(3));
      expect(_json(server.texts[1])['type'], 'finalize');
      expect(server.texts[2], isEmpty);
    });

    test('an error message ends the session as failed', () async {
      final LiveTranscriptionSession session = open(service());
      final List<LiveTranscript> seen = <LiveTranscript>[];
      session.updates.listen(seen.add);
      await server.connected;
      server.send(<String, Object?>{
        'error_code': 401,
        'error_message': 'bad key',
      });
      await _until(() => seen.any((LiveTranscript t) => t.failed));
    });

    test('a drop keeps the committed text and finish returns it', () async {
      final LiveTranscriptionSession session = open(service());
      final List<LiveTranscript> seen = <LiveTranscript>[];
      session.updates.listen(seen.add);
      await server.connected;
      server.send(<String, Object?>{
        'tokens': <Object>[
          <String, Object?>{'text': 'Zapis', 'is_final': true},
        ],
      });
      await _until(() => seen.isNotEmpty);
      await server.socket!.close(WebSocketStatus.goingAway);
      await _until(() => seen.any((LiveTranscript t) => t.failed));
      expect(seen.last.committed, 'Zapis');
      expect(await session.finish(), 'Zapis');
    });

    test('finish times out without the finished marker', () async {
      final LiveTranscriptionSession session = open(
        SonioxLiveService(
          endpoint: server.uri,
          bearerToken: 'k',
          finishTimeout: const Duration(milliseconds: 200),
        ),
      );
      await server.connected;
      server.send(<String, Object?>{
        'tokens': <Object>[
          <String, Object?>{'text': 'Tyle', 'is_final': true},
        ],
      });
      await _until(() => server.socket != null);
      expect(await session.finish(), 'Tyle');
    });

    test('cancel closes the socket', () async {
      final LiveTranscriptionSession session = open(service());
      await server.connected;
      await session.cancel();
      await _until(() => server.socket!.closeCode != null, what: 'closed');
    });
  });

  group('ElevenLabs', () {
    ElevenLabsLiveService service({String? language = 'pl'}) =>
        ElevenLabsLiveService(
          endpoint: server.uri,
          bearerToken: 'el-key',
          language: language,
          finishTimeout: const Duration(seconds: 5),
        );

    test('sends the xi-api-key header and the query parameters', () async {
      open(service());
      await server.connected;
      expect(server.request!.headers.value('xi-api-key'), 'el-key');
      final Map<String, String> q = server.request!.uri.queryParameters;
      expect(q['model_id'], 'scribe_v2_realtime');
      expect(q['audio_format'], 'pcm_16000');
      expect(q['language_code'], 'pl');
      expect(q['commit_strategy'], 'vad');
    });

    test('language_code is left out without a language', () async {
      open(service(language: null));
      await server.connected;
      expect(
        server.request!.uri.queryParameters.containsKey('language_code'),
        isFalse,
      );
    });

    test('audio is a base64 input_audio_chunk text frame', () async {
      final LiveTranscriptionSession session = open(service());
      await server.connected;
      session.addAudio(_pcm(8, 5));
      await _until(() => server.texts.isNotEmpty, what: 'chunk');
      final Map<String, dynamic> frame = _json(server.texts.single);
      expect(frame['message_type'], 'input_audio_chunk');
      expect(base64Decode(frame['audio_base_64'] as String), _pcm(8, 5));
      expect(frame['commit'], false);
      expect(frame['sample_rate'], 16000);
    });

    test(
      'partial replaces, committed appends, session_started is ignored',
      () async {
        final LiveTranscriptionSession session = open(service());
        final List<LiveTranscript> seen = <LiveTranscript>[];
        session.updates.listen(seen.add);
        await server.connected;
        server.send(<String, Object?>{'message_type': 'session_started'});
        server.send(<String, Object?>{
          'message_type': 'partial_transcript',
          'text': 'dzień',
        });
        await _until(
          () => seen.any((LiveTranscript t) => t.partial == 'dzień'),
        );
        server.send(<String, Object?>{
          'message_type': 'committed_transcript',
          'text': 'dzień dobry',
        });
        server.send(<String, Object?>{
          'message_type': 'committed_transcript_with_timestamps',
          'text': 'pani',
        });
        await _until(
          () =>
              seen.any((LiveTranscript t) => t.committed == 'dzień dobry pani'),
        );
        expect(seen.last.partial, '');
      },
    );

    test(
      'finish sends a committing empty chunk and returns the final text',
      () async {
        final LiveTranscriptionSession session = open(service());
        server.onFrame = (_Server s, Object frame) {
          if (frame is String && _json(frame)['commit'] == true) {
            s.send(<String, Object?>{
              'message_type': 'committed_transcript',
              'text': 'całość',
            });
          }
        };
        await server.connected;
        expect(await session.finish(), 'całość');
        final Map<String, dynamic> last = _json(server.texts.last);
        expect(last['audio_base_64'], '');
        expect(last['commit'], true);
      },
    );

    test('an auth_error ends the session as failed', () async {
      final LiveTranscriptionSession session = open(service());
      final List<LiveTranscript> seen = <LiveTranscript>[];
      session.updates.listen(seen.add);
      await server.connected;
      server.send(<String, Object?>{
        'message_type': 'auth_error',
        'error': 'bad key',
      });
      await _until(() => seen.any((LiveTranscript t) => t.failed));
    });

    test(
      'a drop keeps committed text; finish timeout returns the partial',
      () async {
        final LiveTranscriptionSession session = open(
          ElevenLabsLiveService(
            endpoint: server.uri,
            bearerToken: 'k',
            finishTimeout: const Duration(milliseconds: 200),
          ),
        );
        final List<LiveTranscript> seen = <LiveTranscript>[];
        session.updates.listen(seen.add);
        await server.connected;
        server.send(<String, Object?>{
          'message_type': 'committed_transcript',
          'text': 'jeden',
        });
        server.send(<String, Object?>{
          'message_type': 'partial_transcript',
          'text': 'dwa',
        });
        await _until(() => seen.any((LiveTranscript t) => t.partial == 'dwa'));
        // The server never answers the commit.
        expect(await session.finish(), 'jeden dwa');
      },
    );

    test('cancel closes the socket', () async {
      final LiveTranscriptionSession session = open(service());
      await server.connected;
      await session.cancel();
      await _until(() => server.socket!.closeCode != null, what: 'closed');
    });
  });

  group('OpenAI', () {
    OpenAiLiveService service({
      Duration commitEvery = const Duration(seconds: 1),
    }) => OpenAiLiveService(
      endpoint: server.uri,
      bearerToken: 'oa-key',
      language: 'pl',
      model: 'gpt-live-transcribe',
      commitEvery: commitEvery,
      finishTimeout: const Duration(seconds: 5),
    );

    test(
      'declares 24 kHz and sends bearer plus session.update first',
      () async {
        expect(service().sampleRate, 24000);
        open(service());
        await server.connected;
        await _until(() => server.texts.isNotEmpty, what: 'session.update');
        expect(server.request!.headers.value('authorization'), 'Bearer oa-key');
        expect(server.request!.uri.queryParameters['intent'], 'transcription');
        final Map<String, dynamic> update = _json(server.texts.first);
        expect(update['type'], 'session.update');
        final Map<String, dynamic> input =
            ((update['session'] as Map)['audio'] as Map)['input']
                as Map<String, dynamic>;
        expect((input['format'] as Map)['rate'], 24000);
        expect((input['transcription'] as Map)['model'], 'gpt-live-transcribe');
        expect((input['transcription'] as Map)['language'], 'pl');
        expect(input['turn_detection'], isNull);
      },
    );

    test('audio is appended as base64', () async {
      final LiveTranscriptionSession session = open(service());
      await server.connected;
      session.addAudio(_pcm(16, 3));
      await _until(() => server.texts.length == 2, what: 'append');
      final Map<String, dynamic> frame = _json(server.texts.last);
      expect(frame['type'], 'input_audio_buffer.append');
      expect(base64Decode(frame['audio'] as String), _pcm(16, 3));
    });

    test('commits every commitEvery of audio', () async {
      final LiveTranscriptionSession session = open(service());
      await server.connected;
      // 1 s at 24 kHz PCM16 = 48 000 bytes.
      session.addAudio(_pcm(48000));
      await _until(
        () => server.texts.any(
          (String t) => _json(t)['type'] == 'input_audio_buffer.commit',
        ),
        what: 'commit',
      );
    });

    test('deltas build the partial, completed commits it', () async {
      final LiveTranscriptionSession session = open(service());
      final List<LiveTranscript> seen = <LiveTranscript>[];
      session.updates.listen(seen.add);
      await server.connected;
      server.send(<String, Object?>{
        'type': 'conversation.item.input_audio_transcription.delta',
        'item_id': 'a',
        'delta': 'Dzień ',
      });
      server.send(<String, Object?>{
        'type': 'conversation.item.input_audio_transcription.delta',
        'item_id': 'a',
        'delta': 'dobry',
      });
      await _until(
        () => seen.any((LiveTranscript t) => t.partial == 'Dzień dobry'),
      );
      server.send(<String, Object?>{
        'type': 'conversation.item.input_audio_transcription.completed',
        'item_id': 'a',
        'transcript': 'Dzień dobry.',
      });
      await _until(
        () => seen.any(
          (LiveTranscript t) =>
              t.committed == 'Dzień dobry.' && t.partial == '',
        ),
      );
    });

    test('finish commits the tail and waits for its completed event', () async {
      final LiveTranscriptionSession session = open(service());
      server.onFrame = (_Server s, Object frame) {
        if (frame is String &&
            _json(frame)['type'] == 'input_audio_buffer.commit') {
          s.send(<String, Object?>{
            'type': 'conversation.item.input_audio_transcription.completed',
            'item_id': 'z',
            'transcript': 'ogon',
          });
        }
      };
      await server.connected;
      session.addAudio(_pcm(100));
      expect(await session.finish(), 'ogon');
    });

    test('finish with nothing outstanding returns at once', () async {
      final LiveTranscriptionSession session = open(service());
      await server.connected;
      // The service's finishTimeout is 5 s: answering sooner proves it did not
      // wait on a reply that was never owed.
      expect(await session.finish().timeout(const Duration(seconds: 2)), '');
      expect(
        server.texts.any(
          (String t) => _json(t)['type'] == 'input_audio_buffer.commit',
        ),
        isFalse,
      );
    });

    test('finish times out when completed never arrives', () async {
      final LiveTranscriptionSession session = open(
        OpenAiLiveService(
          endpoint: server.uri,
          bearerToken: 'k',
          finishTimeout: const Duration(milliseconds: 200),
        ),
      );
      final List<LiveTranscript> seen = <LiveTranscript>[];
      session.updates.listen(seen.add);
      await server.connected;
      server.send(<String, Object?>{
        'type': 'conversation.item.input_audio_transcription.delta',
        'item_id': 'a',
        'delta': 'niedokończone',
      });
      await _until(() => seen.isNotEmpty);
      session.addAudio(_pcm(100));
      expect(await session.finish(), 'niedokończone');
    });

    test('an error event ends the session as failed', () async {
      final LiveTranscriptionSession session = open(service());
      final List<LiveTranscript> seen = <LiveTranscript>[];
      session.updates.listen(seen.add);
      await server.connected;
      server.send(<String, Object?>{
        'type': 'error',
        'error': <String, Object?>{'message': 'nope'},
      });
      await _until(() => seen.any((LiveTranscript t) => t.failed));
    });

    test('a drop keeps committed text', () async {
      final LiveTranscriptionSession session = open(service());
      final List<LiveTranscript> seen = <LiveTranscript>[];
      session.updates.listen(seen.add);
      await server.connected;
      server.send(<String, Object?>{
        'type': 'conversation.item.input_audio_transcription.completed',
        'item_id': 'a',
        'transcript': 'zostaje',
      });
      await _until(() => seen.isNotEmpty);
      await server.socket!.close(WebSocketStatus.goingAway);
      await _until(() => seen.any((LiveTranscript t) => t.failed));
      expect(seen.last.committed, 'zostaje');
      expect(await session.finish(), 'zostaje');
    });

    test('cancel closes the socket', () async {
      final LiveTranscriptionSession session = open(service());
      await server.connected;
      await session.cancel();
      await _until(() => server.socket!.closeCode != null, what: 'closed');
    });
  });

  group('the provider factory', () {
    test('picks the adapter by host', () {
      expect(liveProviderForHost('api.deepgram.com'), LiveProvider.deepgram);
      expect(liveProviderForHost('stt-rt.soniox.com'), LiveProvider.soniox);
      expect(liveProviderForHost('api.elevenlabs.io'), LiveProvider.elevenlabs);
      expect(liveProviderForHost('api.openai.com'), LiveProvider.openai);
      expect(liveProviderForHost('evil-deepgram.com'), isNull);
    });

    test('builds the matching service with its sample rate', () {
      final LiveTranscriptionService dg = buildLiveTranscriptionService(
        endpoint: Uri.parse('wss://api.deepgram.com/v1/listen'),
      );
      expect(dg, isA<DeepgramLiveService>());
      expect(dg.sampleRate, 16000);
      final LiveTranscriptionService oa = buildLiveTranscriptionService(
        endpoint: Uri.parse('wss://api.openai.com/v1/realtime'),
      );
      expect(oa, isA<OpenAiLiveService>());
      expect(oa.sampleRate, 24000);
    });

    test('an unknown host is disabled', () {
      expect(
        buildLiveTranscriptionService(
          endpoint: Uri.parse('wss://stt.example.org/x'),
        ),
        isA<DisabledLiveTranscriptionService>(),
      );
    });

    test('a provider override reaches a loopback server', () async {
      final LiveTranscriptionService service = buildLiveTranscriptionService(
        endpoint: server.uri,
        bearerToken: 'k',
        provider: LiveProvider.deepgram,
      );
      expect(service.isAvailable, isTrue);
      open(service);
      await server.connected;
      expect(server.request!.headers.value('authorization'), 'Token k');
    });
  });
}
