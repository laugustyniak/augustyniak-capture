import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Pins `record_linux` to the fork that drains ffmpeg's output.
///
/// The published `record_linux` never reads the stderr of the `ffmpeg` it
/// spawns, so once the pipe buffer fills ffmpeg blocks, the take stops growing
/// mid-recording and `stop()` never returns (#168, llfbandit/record#626). The
/// fix lives in a fork reached through `dependency_overrides`, which is a
/// single block in the pubspec that a `flutter pub upgrade`, a merge or a
/// well-meaning cleanup can drop without anything else noticing: the app still
/// builds, every other test still passes, and Linux captures longer than a few
/// minutes silently truncate again. This test fails instead.
///
/// Delete it, and the override, once upstream ships the drain.
void main() {
  test('record_linux resolves from the fork, not pub.dev', () {
    final String lock = File('pubspec.lock').readAsStringSync();
    final RegExp entry = RegExp(
      r'^  record_linux:\r?\n(?:^    .*\r?\n)+',
      multiLine: true,
    );
    final String? block = entry.firstMatch(lock)?.group(0);
    expect(block, isNotNull, reason: 'record_linux missing from pubspec.lock');
    expect(block, contains('source: git'));
    expect(block, contains('url: "https://github.com/laugustyniak/record.git"'));
    expect(block, contains('path: record_linux'));
    // The ref is part of the pin: a bump is a decision to be made here too.
    expect(
      block,
      contains('ref: "7328fdb17928b411af7938ca33c936ccb951f522"'),
    );
  });
}
