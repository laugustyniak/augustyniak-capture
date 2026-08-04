import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:audivoa_core/features/transcription/data/transcription_service.dart';

void main() {
  late Directory tempDir;
  late File audioFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('transcription_test');
    audioFile = File('${tempDir.path}/clip.m4a');
    await audioFile.writeAsBytes(<int>[0, 1, 2, 3, 4]);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('sends file, model and language, parses "text"', () async {
    late String capturedBody;
    late Map<String, String> capturedHeaders;

    final MockClient client = MockClient((http.Request request) async {
      capturedBody = String.fromCharCodes(request.bodyBytes);
      capturedHeaders = request.headers;
      return http.Response(
        '{"text": "  halo świat  "}',
        200,
        headers: <String, String>{
          'content-type': 'application/json; charset=utf-8',
        },
      );
    });

    final HttpWhisperTranscriptionService service =
        HttpWhisperTranscriptionService(
          endpoint: Uri.parse('https://api.openai.com/v1/audio/transcriptions'),
          bearerToken: 'sk-test',
          model: 'whisper-1',
          language: 'pl',
          client: client,
        );

    final String text = await service.transcribe(audioFile);

    expect(text, 'halo świat'); // trimmed
    expect(capturedBody, contains('name="file"'));
    expect(capturedBody, contains('name="model"'));
    expect(capturedBody, contains('whisper-1'));
    expect(capturedBody, contains('name="language"'));
    expect(capturedBody, contains('pl'));
    expect(capturedHeaders['authorization'], 'Bearer sk-test');
  });

  test('falls back to "transcript" key', () async {
    final MockClient client = MockClient((http.Request request) async {
      return http.Response('{"transcript": "fallback"}', 200);
    });

    final HttpWhisperTranscriptionService service =
        HttpWhisperTranscriptionService(
          endpoint: Uri.parse('https://example.com/transcribe'),
          client: client,
        );

    expect(await service.transcribe(audioFile), 'fallback');
  });

  test('omits model/language fields when not provided', () async {
    late String capturedBody;
    final MockClient client = MockClient((http.Request request) async {
      capturedBody = String.fromCharCodes(request.bodyBytes);
      return http.Response('{"text": "x"}', 200);
    });

    final HttpWhisperTranscriptionService service =
        HttpWhisperTranscriptionService(
          endpoint: Uri.parse('https://example.com/transcribe'),
          client: client,
        );

    await service.transcribe(audioFile);
    expect(capturedBody, isNot(contains('name="model"')));
    expect(capturedBody, isNot(contains('name="language"')));
  });

  test('non-2xx response throws HttpException', () async {
    final MockClient client = MockClient((http.Request request) async {
      return http.Response('{"error": "bad key"}', 401);
    });

    final HttpWhisperTranscriptionService service =
        HttpWhisperTranscriptionService(
          endpoint: Uri.parse('https://example.com/transcribe'),
          client: client,
        );

    expect(() => service.transcribe(audioFile), throwsA(isA<HttpException>()));
  });

  test('missing text/transcript throws FormatException', () async {
    final MockClient client = MockClient((http.Request request) async {
      return http.Response('{"unexpected": true}', 200);
    });

    final HttpWhisperTranscriptionService service =
        HttpWhisperTranscriptionService(
          endpoint: Uri.parse('https://example.com/transcribe'),
          client: client,
        );

    expect(
      () => service.transcribe(audioFile),
      throwsA(isA<FormatException>()),
    );
  });
}
