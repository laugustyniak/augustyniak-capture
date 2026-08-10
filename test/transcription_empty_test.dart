import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';

/// A recording with no speech is not a malformed response.
///
/// OpenAI answers `{"text":"","languages":[],"usage":{…}}` with HTTP 200 for
/// three seconds of silence — a correct answer to a correct request. The parser
/// read the empty string as a missing field and reported "Response does not
/// contain text or transcript", which sends whoever reads the Logs tab looking
/// at the API contract when the only thing that happened is that nobody spoke.
void main() {
  late Directory dir;
  late File audio;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('transcribe-empty-');
    audio = File('${dir.path}/capture.m4a')..writeAsBytesSync(<int>[1, 2, 3]);
  });

  tearDown(() => dir.deleteSync(recursive: true));

  HttpWhisperTranscriptionService serviceReturning(Object body) =>
      HttpWhisperTranscriptionService(
        endpoint: Uri.parse('https://api.openai.com/v1/audio/transcriptions'),
        client: MockClient(
          (http.Request request) async => http.Response(jsonEncode(body), 200),
        ),
      );

  test('silence is reported as silence, not as a broken response', () async {
    await expectLater(
      serviceReturning(<String, dynamic>{
        'text': '',
        'languages': <String>[],
        'usage': <String, dynamic>{'type': 'duration', 'seconds': 3},
      }).transcribe(audio),
      throwsA(
        isA<FormatException>().having(
          (FormatException e) => e.message,
          'message',
          contains('no speech'),
        ),
      ),
    );
  });

  test('whitespace counts as silence too', () async {
    await expectLater(
      serviceReturning(<String, dynamic>{'text': '   \n '}).transcribe(audio),
      throwsA(
        isA<FormatException>().having(
          (FormatException e) => e.message,
          'message',
          contains('no speech'),
        ),
      ),
    );
  });

  test('a genuinely malformed response still says so', () async {
    // The distinction has to survive the fix: a body with no text field at all
    // is a contract problem, and calling that silence would send the next
    // reader looking at the microphone instead of the response.
    await expectLater(
      serviceReturning(<String, dynamic>{'unexpected': 1}).transcribe(audio),
      throwsA(
        isA<FormatException>().having(
          (FormatException e) => e.message,
          'message',
          contains('does not contain'),
        ),
      ),
    );
  });

  test('a real transcript still comes back trimmed', () async {
    expect(
      await serviceReturning(<String, dynamic>{
        'text': '  hello there  ',
      }).transcribe(audio),
      'hello there',
    );
  });
}
