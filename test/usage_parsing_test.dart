import 'dart:convert';

import 'package:augustyniak_capture/features/costs/domain/usage_parsing.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _decode(String body) =>
    jsonDecode(body) as Map<String, dynamic>;

void main() {
  group('parseUsage', () {
    test('reads an OpenAI chat completion usage block', () {
      final MeasuredUsage usage = parseUsage(_decode('''
        {"choices": [], "usage": {"prompt_tokens": 1200, "completion_tokens": 90}}
      '''));

      expect(usage.inputTokens, 1200);
      expect(usage.outputTokens, 90);
      expect(usage.audioSeconds, isNull);
    });

    test('reads the input_tokens/output_tokens spelling', () {
      final MeasuredUsage usage = parseUsage(_decode('''
        {"usage": {"input_tokens": 800, "output_tokens": 40}}
      '''));

      expect(usage.inputTokens, 800);
      expect(usage.outputTokens, 40);
    });

    test('reads a duration usage block as audio seconds', () {
      final MeasuredUsage usage = parseUsage(_decode('''
        {"text": "hi", "usage": {"type": "duration", "seconds": 137.5}}
      '''));

      expect(usage.audioSeconds, closeTo(137.5, 1e-9));
      expect(usage.inputTokens, isNull);
    });

    test('reads Groq usage nested under x_groq', () {
      final MeasuredUsage usage = parseUsage(_decode('''
        {"text": "hi", "x_groq": {"usage": {"seconds": 42}}}
      '''));

      expect(usage.audioSeconds, closeTo(42, 1e-9));
    });

    test('a response with no usage block is empty, not an error', () {
      final MeasuredUsage usage = parseUsage(_decode('{"text": "hi"}'));

      expect(usage.isEmpty, isTrue);
      expect(usage.inputTokens, isNull);
      expect(usage.outputTokens, isNull);
      expect(usage.audioSeconds, isNull);
    });

    test('a non-numeric usage value is ignored rather than thrown', () {
      final MeasuredUsage usage = parseUsage(_decode('''
        {"usage": {"prompt_tokens": "many", "completion_tokens": 7}}
      '''));

      expect(usage.inputTokens, isNull);
      expect(usage.outputTokens, 7);
    });

    test('numeric-looking strings are not parsed as numbers', () {
      final MeasuredUsage usage = parseUsage(_decode('''
        {"usage": {"prompt_tokens": "7", "completion_tokens": 7}}
      '''));

      expect(usage.inputTokens, isNull);
      expect(usage.outputTokens, 7);
    });
  });
}
