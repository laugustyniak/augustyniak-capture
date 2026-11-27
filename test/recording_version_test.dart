import 'dart:convert';

import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording_version.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// Type to be created by #474 in `recording_version.dart`:
/// `String recordingVersion(Recording r)`.
void main() {
  Recording sample({String? transcript}) => Recording(
    id: 'v1',
    filePath: '/x/v1.m4a',
    createdAt: DateTime.utc(2026, 11, 27, 9),
    durationMs: 10,
    status: RecordingStatus.completed,
    title: 'Zażółć',
    transcript: transcript ?? 'gęślą jaźń 😀',
  );

  test('is sha256 of the utf8 of jsonEncode(toJson())', () {
    // AC-4
    final Recording r = sample();
    expect(
      recordingVersion(r),
      sha256.convert(utf8.encode(jsonEncode(r.toJson()))).toString(),
    );
  });

  test('is stable across a JSON round trip and changes with content', () {
    // AC-4
    final Recording r = sample();
    final Recording back = Recording.fromJson(
      jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>,
    );
    expect(recordingVersion(back), recordingVersion(r));
    expect(
      recordingVersion(sample(transcript: 'other')),
      isNot(recordingVersion(r)),
    );
  });
}
