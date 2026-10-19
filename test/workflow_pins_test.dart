import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Pins the supply-chain posture of the GitHub workflows: every third-party
/// action is addressed by commit SHA (a tag can be moved, a SHA cannot) and the
/// token every job receives is read-only unless a job asks for more.
///
/// Nothing in Dart exercises these files, and a mutable `@v7` looks identical
/// to a pinned one in a green run.
void main() {
  final Directory dir = Directory('.github/workflows');
  final List<File> workflows = dir
      .listSync()
      .whereType<File>()
      .where((File f) => f.path.endsWith('.yml'))
      .toList();

  // A SHA followed by the release it stands for, so a bump stays reviewable.
  final RegExp pinned = RegExp(
    r'^\s*-?\s*uses:\s*[^@\s]+@[0-9a-f]{40}\s+#\s*v\S+',
  );
  final RegExp usesLine = RegExp(r'^\s*-?\s*uses:\s*(\S+)');

  test('there are workflows to check', () {
    expect(workflows, isNotEmpty);
  });

  test('every action is pinned to a commit SHA with a version comment', () {
    final List<String> loose = <String>[];
    for (final File file in workflows) {
      for (final String line in file.readAsLinesSync()) {
        final RegExpMatch? m = usesLine.firstMatch(line);
        if (m == null) continue;
        // A local action is part of the commit being built; nothing to pin.
        if (m.group(1)!.startsWith('./')) continue;
        if (!pinned.hasMatch(line)) loose.add('${file.path}: ${line.trim()}');
      }
    }
    expect(loose, isEmpty);
  });

  test('ci.yml grants the token read-only contents at the top level', () {
    final List<String> lines = File(
      '.github/workflows/ci.yml',
    ).readAsLinesSync();
    final int at = lines.indexOf('permissions:');
    expect(at, isNot(-1), reason: 'no top-level permissions block');

    final List<String> block = <String>[];
    for (final String line in lines.skip(at + 1)) {
      if (line.trim().isEmpty || line.trim().startsWith('#')) continue;
      if (!line.startsWith(' ')) break;
      block.add(line.trim());
    }
    expect(block, contains('contents: read'));
    expect(block.where((String l) => l.endsWith(': write')), isEmpty);
  });
}
