import 'dart:convert';

import 'package:augustyniak_capture/features/enrichment/data/http_chat_enrichment_service.dart';
import 'package:augustyniak_capture/features/enrichment/domain/enrichment_context.dart';
import 'package:augustyniak_capture/features/recordings/domain/connection_reasoner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'model advice uses supplied goals and candidates without taking action',
    () async {
      late Map<String, dynamic> request;
      final service = HttpChatEnrichmentService(
        endpoint: Uri.parse('https://example.test/v1/chat/completions'),
        model: 'test-model',
        client: MockClient((http.Request call) async {
          request = jsonDecode(call.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode(<String, dynamic>{
              'choices': <Map<String, dynamic>>[
                <String, dynamic>{
                  'message': <String, String>{
                    'content': jsonEncode(<String, String>{
                      'decision': 'actNow',
                      'reason': 'Supports the current vault goal.',
                      'nextStep': 'Review the import plan.',
                    }),
                  },
                },
              ],
            }),
            200,
          );
        }),
      );

      final ConnectionAdvice advice = await service.assess(
        title: 'Import notes',
        text: 'Connect new captures with the vault.',
        candidates: const <ConnectionCandidate>[
          ConnectionCandidate(
            path: '/vault/Plan.md',
            title: 'Vault plan',
            sharedTerms: <String>['vault'],
            excerpt: 'Plan the vault import.',
          ),
        ],
        context: const EnrichmentContext(profile: 'Goal: organize notes.'),
      );

      expect(advice.decision, ConnectionDecision.actNow);
      expect(advice.nextStep, 'Review the import plan.');
      final messages = request['messages'] as List<dynamic>;
      final input =
          jsonDecode(
                (messages.last as Map<String, dynamic>)['content'] as String,
              )
              as Map<String, dynamic>;
      expect(input['profile'], 'Goal: organize notes.');
      expect(
        (input['relatedNotes'] as List<dynamic>).single['title'],
        'Vault plan',
      );
      expect(input.toString(), isNot(contains('/vault/Plan.md')));
    },
  );
}
