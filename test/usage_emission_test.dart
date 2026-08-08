import 'dart:convert';

import 'package:augustyniak_capture/features/costs/domain/usage_event.dart';
import 'package:augustyniak_capture/features/costs/domain/usage_parsing.dart';
import 'package:augustyniak_capture/features/costs/domain/usage_sink.dart';
import 'package:augustyniak_capture/features/enrichment/data/http_chat_enrichment_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _RecordingSink implements UsageSink {
  final List<String> jobs = <String>[];
  final List<MeasuredUsage> recorded = <MeasuredUsage>[];
  final List<String> models = <String>[];
  int ends = 0;

  @override
  void beginJob(
    String captureId,
    UsageStage stage, {
    double? fallbackAudioSeconds,
  }) {
    jobs.add('$captureId/${stage.name}');
  }

  @override
  void endJob() => ends++;

  @override
  void record({
    required String provider,
    required String model,
    required MeasuredUsage usage,
  }) {
    models.add(model);
    recorded.add(usage);
  }
}

void main() {
  test('a successful enrichment response emits its usage once', () async {
    final _RecordingSink sink = _RecordingSink();
    final http.Client client = MockClient((http.Request request) async {
      return http.Response(
        jsonEncode(<String, dynamic>{
          'choices': <dynamic>[
            <String, dynamic>{
              'message': <String, dynamic>{
                'content':
                    '{"title":"T","category":"note","summary":"S","tags":[]}',
              },
            },
          ],
          'usage': <String, dynamic>{
            'prompt_tokens': 1200,
            'completion_tokens': 90,
          },
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });

    final HttpChatEnrichmentService service = HttpChatEnrichmentService(
      endpoint: Uri.parse('https://api.openai.com/v1/chat/completions'),
      model: 'gpt-5.6-luna',
      client: client,
      usageSink: sink,
    );

    await service.enrich('hello');

    expect(sink.recorded, hasLength(1));
    expect(sink.recorded.single.inputTokens, 1200);
    expect(sink.recorded.single.outputTokens, 90);
    expect(sink.models.single, 'gpt-5.6-luna');
  });

  test('a failed response emits nothing', () async {
    final _RecordingSink sink = _RecordingSink();
    final http.Client client = MockClient(
      (http.Request request) async => http.Response('nope', 500),
    );

    final HttpChatEnrichmentService service = HttpChatEnrichmentService(
      endpoint: Uri.parse('https://api.openai.com/v1/chat/completions'),
      model: 'gpt-5.6-luna',
      client: client,
      usageSink: sink,
    );

    await expectLater(service.enrich('hello'), throwsA(isA<Exception>()));
    expect(sink.recorded, isEmpty);
  });

  test('a throwing sink never fails the enrichment', () async {
    final http.Client client = MockClient((http.Request request) async {
      return http.Response(
        jsonEncode(<String, dynamic>{
          'choices': <dynamic>[
            <String, dynamic>{
              'message': <String, dynamic>{
                'content':
                    '{"title":"T","category":"note","summary":"S","tags":[]}',
              },
            },
          ],
          'usage': <String, dynamic>{'prompt_tokens': 1},
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });

    final HttpChatEnrichmentService service = HttpChatEnrichmentService(
      endpoint: Uri.parse('https://api.openai.com/v1/chat/completions'),
      model: 'gpt-5.6-luna',
      client: client,
      usageSink: _ThrowingSink(),
    );

    final dynamic result = await service.enrich('hello');
    expect(result.title, 'T');
  });
}

class _ThrowingSink implements UsageSink {
  @override
  void beginJob(
    String captureId,
    UsageStage stage, {
    double? fallbackAudioSeconds,
  }) => throw StateError('boom');

  @override
  void endJob() => throw StateError('boom');

  @override
  void record({
    required String provider,
    required String model,
    required MeasuredUsage usage,
  }) => throw StateError('boom');
}
