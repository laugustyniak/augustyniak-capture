import 'dart:io';

import 'package:augustyniak_capture/core/http/bounded_client.dart';
import 'package:augustyniak_capture/features/command/data/http_command_client.dart';
import 'package:augustyniak_capture/features/connections/data/http_daily_connections_service.dart';
import 'package:augustyniak_capture/features/enrichment/data/http_chat_enrichment_service.dart';
import 'package:augustyniak_capture/features/enrichment/data/http_embedding_service.dart';
import 'package:augustyniak_capture/features/processing/data/http_vision_ocr_service.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/settings/domain/provider_profile.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';
import 'package:augustyniak_capture/features/work_dashboard/data/todoist_reader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A body one byte past [limit], so each test proves its own ceiling bites.
MockClient _oversized(int limit) => MockClient(
  (http.Request request) async => http.Response('x' * (limit + 1), 200),
);

void main() {
  final Uri endpoint = Uri.parse('https://api.example.com/v1/x');
  final Matcher tooLarge = throwsA(isA<ResponseTooLargeException>());

  test('chat enrichment refuses an oversized body', () async {
    final HttpChatEnrichmentService service = HttpChatEnrichmentService(
      endpoint: endpoint,
      client: _oversized(HttpChatEnrichmentService.maxResponseBytes),
    );
    await expectLater(service.enrich('text'), tooLarge);
  });

  test('embedding refuses an oversized body', () async {
    final HttpEmbeddingService service = HttpEmbeddingService(
      endpoint: endpoint,
      model: 'm',
      client: _oversized(HttpEmbeddingService.maxResponseBytes),
    );
    await expectLater(service.embed('text'), tooLarge);
  });

  test('vision OCR refuses an oversized body', () async {
    final Directory dir = await Directory.systemTemp.createTemp('ceiling_ocr');
    addTearDown(() => dir.delete(recursive: true));
    final File image = File('${dir.path}/a.png');
    await image.writeAsBytes(<int>[0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0, 0, 0]);
    final HttpVisionOcrService service = HttpVisionOcrService(
      endpoint: endpoint,
      client: _oversized(HttpVisionOcrService.maxResponseBytes),
    );
    await expectLater(service.extractText(image), tooLarge);
  });

  test('transcription refuses an oversized body', () async {
    final Directory dir = await Directory.systemTemp.createTemp('ceiling_stt');
    addTearDown(() => dir.delete(recursive: true));
    final File audio = File('${dir.path}/a.m4a');
    await audio.writeAsBytes(<int>[0, 1, 2]);
    final HttpWhisperTranscriptionService service =
        HttpWhisperTranscriptionService(
          endpoint: endpoint,
          client: _oversized(HttpWhisperTranscriptionService.maxResponseBytes),
        );
    await expectLater(service.transcribe(audio), tooLarge);
  });

  test('command client refuses an oversized body', () async {
    final HttpCommandClient client = HttpCommandClient(
      baseUrl: Uri.parse('https://command.example.com/'),
      client: _oversized(HttpCommandClient.maxResponseBytes),
    );
    await expectLater(client.hosts(), tooLarge);
  });

  test('daily connections refuses an oversized body', () async {
    final HttpDailyConnectionsService service = HttpDailyConnectionsService(
      activeProfile: () => const ProviderProfile(
        id: 'p',
        name: 'Model',
        endpoint: 'https://example.com/chat',
        kind: ProfileKind.enrichment,
      ),
      client: _oversized(HttpDailyConnectionsService.maxResponseBytes),
    );
    final Recording capture = Recording(
      id: 'one',
      filePath: '/tmp/one.txt',
      createdAt: DateTime(2026, 10, 3, 8),
      durationMs: 0,
      status: RecordingStatus.completed,
      type: CaptureType.text,
      transcript: 'Some words',
    );
    await expectLater(
      service.review(DateTime(2026, 10, 3), <Recording>[capture]),
      tooLarge,
    );
    service.close();
  });

  test('todoist reader refuses an oversized body', () async {
    final TodoistReader reader = TodoistReader(
      client: _oversized(TodoistReader.maxResponseBytes),
      baseUrl: Uri.parse('https://api.todoist.test/api/v1/'),
    );
    await expectLater(reader.load('token'), tooLarge);
  });
}
