import 'package:augustyniak_capture/features/recordings/domain/capture_prompt.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_router.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:flutter_test/flutter_test.dart';

RoutedCapture capture({String body = '', String? summary, String title = ''}) =>
    RoutedCapture(
      id: 'r1',
      projectId: null,
      title: title,
      body: body,
      summary: summary,
      capturedAt: DateTime(2026, 10, 6),
      type: CaptureType.audioRecording,
    );

void main() {
  test('the trimmed body is the whole prompt', () {
    expect(
      capturePrompt(capture(body: '  ask about X \n', summary: 's', title: 't')),
      'ask about X',
    );
  });

  test('a blank body falls back to the summary', () {
    expect(
      capturePrompt(capture(body: '  \n', summary: ' the gist ', title: 't')),
      'the gist',
    );
  });

  test('no body and no summary falls back to the title', () {
    expect(capturePrompt(capture(title: ' Recording 14:32 ')), 'Recording 14:32');
  });

  test('a capture with nothing at all answers empty', () {
    expect(capturePrompt(capture()), isEmpty);
  });
}
