import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:voice_notes_phase1/features/enrichment/data/http_chat_enrichment_service.dart';
import 'package:voice_notes_phase1/features/enrichment/domain/enrichment_prompt.dart';
import 'package:voice_notes_phase1/features/enrichment/domain/enrichment_result.dart';
import 'package:voice_notes_phase1/features/enrichment/domain/enrichment_service.dart';
import 'package:voice_notes_phase1/features/recordings/domain/capture_category.dart';

void main() {
  group('CaptureCategory', () {
    test('null and unknown names both degrade to capture', () {
      expect(CaptureCategory.fromName(null), CaptureCategory.capture);
      expect(CaptureCategory.fromName('journal'), CaptureCategory.capture);
      expect(CaptureCategory.fromName(''), CaptureCategory.capture);
    });

    test('known names round-trip', () {
      for (final CaptureCategory value in CaptureCategory.values) {
        expect(CaptureCategory.fromName(value.name), value);
      }
    });

    test('every category has a non-empty Polish label', () {
      for (final CaptureCategory value in CaptureCategory.values) {
        expect(value.label.trim(), isNotEmpty);
      }
    });
  });

  group('enrichment prompt', () {
    test('lists every category, so the prompt cannot desync from the enum', () {
      final String prompt = buildEnrichmentSystemPrompt();
      for (final CaptureCategory value in CaptureCategory.values) {
        expect(prompt, contains(value.name));
      }
    });

    test('short text is passed through untouched', () {
      expect(truncateForEnrichment('krótka notatka'), 'krótka notatka');
    });

    test('long text keeps its head and its tail', () {
      final String long = '${'a' * 20000}KONIEC';
      final String cut = truncateForEnrichment(long);

      expect(cut.length, lessThan(long.length));
      expect(cut.startsWith('aaa'), isTrue);
      // The closing words of a recording usually carry the conclusion, so the
      // tail has to survive.
      expect(cut.endsWith('KONIEC'), isTrue);
      expect(cut, contains('[...]'));
    });
  });

  group('DisabledEnrichmentService', () {
    test('throws the not-configured exception', () {
      expect(
        () => const DisabledEnrichmentService().enrich('cokolwiek'),
        throwsA(isA<EnrichmentNotConfiguredException>()),
      );
    });
  });

  group('HttpChatEnrichmentService', () {
    HttpChatEnrichmentService serviceReturning(
      String body, {
      int status = 200,
      void Function(http.Request request)? onRequest,
    }) {
      return HttpChatEnrichmentService(
        endpoint: Uri.parse('https://api.example.com/v1/chat/completions'),
        bearerToken: 'sk-test',
        model: 'gpt-4o-mini',
        client: MockClient((http.Request request) async {
          onRequest?.call(request);
          return http.Response(
            body,
            status,
            headers: <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }),
      );
    }

    String chatBody(String content) => jsonEncode(<String, dynamic>{
          'choices': <dynamic>[
            <String, dynamic>{
              'message': <String, dynamic>{'content': content},
            },
          ],
        });

    String userContent(Map<String, dynamic> sent) =>
        ((sent['messages'] as List<dynamic>).last
            as Map<String, dynamic>)['content'] as String;

    test('sends model, token and JSON response format', () async {
      late Map<String, dynamic> sent;
      late Map<String, String> headers;

      final HttpChatEnrichmentService service = serviceReturning(
        chatBody('{"title":"T","category":"note","summary":"S","tags":["a"]}'),
        onRequest: (http.Request request) {
          sent = jsonDecode(utf8.decode(request.bodyBytes))
              as Map<String, dynamic>;
          headers = request.headers;
        },
      );

      await service.enrich('treść notatki');

      expect(sent['model'], 'gpt-4o-mini');
      expect(
        (sent['response_format'] as Map<String, dynamic>)['type'],
        'json_object',
      );
      expect(headers['Authorization'], 'Bearer sk-test');
      final List<dynamic> messages = sent['messages'] as List<dynamic>;
      expect(messages.length, 2);
      expect((messages.first as Map<String, dynamic>)['role'], 'system');
      // Polish survives the round trip: the body is UTF-8 encoded explicitly
      // rather than left to `http`'s latin-1 default.
      expect(userContent(sent), 'treść notatki');
    });

    test('parses a clean response', () async {
      final EnrichmentResult result = await serviceReturning(chatBody(
        '{"title":"Spotkanie z klientem","category":"meetingNote",'
        '"summary":"Ustalenia.","tags":["Klient","OFERTA"]}',
      )).enrich('...');

      expect(result.title, 'Spotkanie z klientem');
      expect(result.category, CaptureCategory.meetingNote);
      expect(result.summary, 'Ustalenia.');
      expect(result.tags, <String>['klient', 'oferta']);
    });

    test('strips a markdown code fence around the JSON', () async {
      final EnrichmentResult result = await serviceReturning(chatBody(
        '```json\n{"title":"T","category":"task"}\n```',
      )).enrich('...');

      expect(result.title, 'T');
      expect(result.category, CaptureCategory.task);
    });

    test('an unknown category degrades to capture', () async {
      final EnrichmentResult result = await serviceReturning(
        chatBody('{"title":"T","category":"journal"}'),
      ).enrich('...');

      expect(result.category, CaptureCategory.capture);
    });

    test('a missing category degrades to capture', () async {
      final EnrichmentResult result =
          await serviceReturning(chatBody('{"title":"T"}')).enrich('...');

      expect(result.category, CaptureCategory.capture);
      expect(result.tags, isEmpty);
      expect(result.summary, isNull);
    });

    test('a blank title becomes null and tags are capped at five', () async {
      final EnrichmentResult result = await serviceReturning(chatBody(
        '{"title":"   ","category":"note",'
        '"tags":["a","b","c","d","e","f","a"]}',
      )).enrich('...');

      expect(result.title, isNull);
      expect(result.tags, <String>['a', 'b', 'c', 'd', 'e']);
    });

    test('a non-JSON content body throws', () async {
      expect(
        () => serviceReturning(chatBody('nie wiem')).enrich('...'),
        throwsA(isA<FormatException>()),
      );
    });

    test('a response with no choices throws', () async {
      expect(
        () => serviceReturning('{"choices":[]}').enrich('...'),
        throwsA(isA<FormatException>()),
      );
    });

    test('a non-2xx response throws', () async {
      expect(
        () => serviceReturning('{"error":"nope"}', status: 401).enrich('...'),
        throwsA(isA<HttpException>()),
      );
    });

    test('long input is truncated before it is sent', () async {
      late Map<String, dynamic> sent;
      final HttpChatEnrichmentService service = serviceReturning(
        chatBody('{"title":"T","category":"note"}'),
        onRequest: (http.Request request) => sent =
            jsonDecode(utf8.decode(request.bodyBytes)) as Map<String, dynamic>,
      );

      await service.enrich('x' * 30000);

      expect(userContent(sent).length, lessThan(30000));
      expect(userContent(sent), contains('[...]'));
    });
  });
}
