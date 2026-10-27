import 'package:augustyniak_capture/features/costs/data/litellm_price_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('converts exact token and audio rates into app units', () async {
    final LiteLlmPriceService service = LiteLlmPriceService(
      client: MockClient(
        (http.Request request) async => http.Response('''{
        "gpt-5.6-luna":{"input_cost_per_token":2e-7,"output_cost_per_token":1.2e-6},
        "gpt-transcribe":{"input_cost_per_second":7.5e-5},
        "whisper-1":{"input_cost_per_second":0.0001,"output_cost_per_second":0.0001},
        "groq/whisper-large-v3":{"input_cost_per_second":3.083e-5}
      }''', 200),
      ),
    );

    final chat = await service.fetch('gpt-5.6-luna', isTranscription: false);
    final transcribe = await service.fetch(
      'gpt-transcribe',
      isTranscription: true,
    );
    final whisper = await service.fetch('whisper-1', isTranscription: true);
    final groq = await service.fetch('whisper-large-v3', isTranscription: true);

    expect(chat.inputPerMTok, 0.2);
    expect(chat.outputPerMTok, 1.2);
    expect(transcribe.perAudioMinute, 0.0045);
    expect(whisper.perAudioMinute, 0.006);
    expect(groq.perAudioMinute, closeTo(0.0018498, 1e-12));
  });

  test('rejects missing and incomplete exact entries', () async {
    final LiteLlmPriceService service = LiteLlmPriceService(
      client: MockClient(
        (http.Request request) async =>
            http.Response('{"known":{"input_cost_per_token":2e-7}}', 200),
      ),
    );

    expect(
      service.fetch('unknown', isTranscription: false),
      throwsA(isA<PriceNotFoundException>()),
    );
    expect(
      service.fetch('known', isTranscription: false),
      throwsA(isA<PriceCatalogException>()),
    );
  });

  test('rejects negative rates and catalog request failures', () async {
    final LiteLlmPriceService invalid = LiteLlmPriceService(
      client: MockClient((http.Request request) async => http.Response(
            '{"bad":{"input_cost_per_second":-0.1}}',
            200,
          )),
    );
    final LiteLlmPriceService unavailable = LiteLlmPriceService(
      client: MockClient((http.Request request) async => http.Response('', 503)),
    );

    expect(
      invalid.fetch('bad', isTranscription: true),
      throwsA(isA<PriceCatalogException>()),
    );
    expect(
      unavailable.fetch('bad', isTranscription: true),
      throwsA(isA<PriceCatalogException>()),
    );
  });

  test('uses only explicit aliases for shipped Groq model names', () async {
    final LiteLlmPriceService service = LiteLlmPriceService(
      client: MockClient((http.Request request) async => http.Response('''{
        "groq/whisper-large-v3-turbo":{"input_cost_per_second":1.111e-5},
        "groq/llama-3.3-70b-versatile":{"input_cost_per_token":5.9e-8,"output_cost_per_token":7.9e-8},
        "groq/openai/gpt-oss-120b":{"input_cost_per_token":1.5e-7,"output_cost_per_token":6e-7},
        "groq/openai/gpt-oss-20b":{"input_cost_per_token":7.5e-8,"output_cost_per_token":3e-7}
      }''', 200)),
    );

    expect(
      (await service.fetch(
        'whisper-large-v3-turbo',
        isTranscription: true,
      )).perAudioMinute,
      closeTo(0.0006666, 1e-12),
    );
    expect(
      (await service.fetch(
        'llama-3.3-70b-versatile',
        isTranscription: false,
      )).inputPerMTok,
      0.059,
    );
    expect(
      (await service.fetch(
        'openai/gpt-oss-120b',
        isTranscription: false,
      )).outputPerMTok,
      0.6,
    );
    expect(
      (await service.fetch(
        'openai/gpt-oss-20b',
        isTranscription: false,
      )).inputPerMTok,
      0.075,
    );
  });
}
