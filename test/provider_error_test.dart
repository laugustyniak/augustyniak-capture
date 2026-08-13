import 'package:augustyniak_capture/core/http/provider_failure.dart';
import 'package:flutter_test/flutter_test.dart';

/// A failed provider call reports the response body, and that body is not
/// always the provider's own words: a 4xx from a chat endpoint routinely quotes
/// the request back, and the request carries the transcript plus the project
/// context this app read off disk. The message then lands in the capture's
/// `error` field, in the Logs tab, and in whatever the user pastes from there.
///
/// The status code and the opening of the body are what diagnose the failure —
/// `model_not_found`, `invalid_api_key`, a rate limit. The rest is bulk.
void main() {
  group('describeProviderFailure', () {
    test('keeps the status code and the start of the body', () {
      expect(
        describeProviderFailure('Transcription', 401, 'invalid_api_key'),
        'Transcription failed (401): invalid_api_key',
      );
    });

    test('truncates a long body rather than carrying all of it', () {
      final String body = 'x' * 5000;

      final String message = describeProviderFailure('Enrichment', 400, body);

      expect(message.length, lessThan(400));
      expect(message, startsWith('Enrichment failed (400): '));
      expect(message, endsWith('…'));
    });

    test('collapses newlines — this is one line in a log and a card', () {
      expect(
        describeProviderFailure('OCR', 500, 'first\nsecond\n\nthird'),
        'OCR failed (500): first second third',
      );
    });

    test('an empty body still names the status', () {
      // A bare 502 from a proxy has no body at all, and "failed ():" reads as
      // a bug in this app rather than a failure at the other end.
      expect(
        describeProviderFailure('Transcription', 502, '   '),
        'Transcription failed (502).',
      );
    });
  });
}
