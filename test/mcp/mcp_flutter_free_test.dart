import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The server is compiled with `dart compile exe`, which cannot link
/// `dart:ui`. One transitive `package:flutter` import breaks the build, and
/// `core/database/app_database.dart` (debugPrint) is the easy one to reach for.
void main() {
  test('bin/capture_mcp.dart has no transitive package:flutter import', () {
    final Set<String> seen = <String>{};
    final List<File> queue = <File>[
      File('bin/capture_mcp.dart'),
      ...Directory('lib/features/mcp')
          .listSync(recursive: true)
          .whereType<File>()
          .where((File f) => f.path.endsWith('.dart')),
    ];
    final RegExp importLine = RegExp(
      r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''',
      multiLine: true,
    );
    final List<String> offenders = <String>[];
    while (queue.isNotEmpty) {
      final File file = queue.removeLast();
      if (!seen.add(file.path)) continue;
      expect(file.existsSync(), isTrue, reason: file.path);
      for (final RegExpMatch m in importLine.allMatches(
        file.readAsStringSync(),
      )) {
        final String target = m.group(1)!;
        if (target.startsWith('package:flutter')) {
          offenders.add('${file.path} -> $target');
        } else if (target.startsWith('package:augustyniak_capture/')) {
          queue.add(
            File(target.replaceFirst('package:augustyniak_capture/', 'lib/')),
          );
        } else if (!target.contains(':')) {
          queue.add(File.fromUri(file.uri.resolve(target)));
        }
      }
    }
    expect(offenders, isEmpty);
    expect(seen.length, greaterThan(5));
  });
}
