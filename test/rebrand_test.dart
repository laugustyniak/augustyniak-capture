import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'tracked content and paths contain no legacy product identity',
    () async {
      final String legacy = <String>['audi', 'voa'].join();
      final ProcessResult content = await Process.run('git', <String>[
        'grep',
        '-n',
        '-I',
        '-i',
        legacy,
      ]);
      final ProcessResult paths = await Process.run('git', <String>[
        'ls-files',
        '-co',
        '--exclude-standard',
      ]);
      final String activePaths = '${paths.stdout}'
          .split('\n')
          .where(
            (String path) =>
                path.isNotEmpty &&
                FileSystemEntity.typeSync(path) !=
                    FileSystemEntityType.notFound,
          )
          .join('\n');

      expect(
        content.exitCode,
        1,
        reason:
            'Legacy identity remains in tracked content:\n${content.stdout}',
      );
      expect(paths.exitCode, 0, reason: '${paths.stderr}');
      expect(
        activePaths.toLowerCase(),
        isNot(contains(legacy)),
        reason: 'Legacy identity remains in a tracked path.',
      );
    },
  );

  test('platforms share the canonical Augustyniak Capture identity', () {
    const String displayName = 'Augustyniak Capture';
    const String packageName = 'augustyniak_capture';
    const String applicationId = 'ai.augustyniak.capture';

    expect(
      File('pubspec.yaml').readAsStringSync(),
      startsWith('name: $packageName'),
    );
    expect(File('lib/app/app.dart').readAsStringSync(), contains(displayName));
    expect(
      File('android/app/build.gradle.kts').readAsStringSync(),
      allOf(contains(applicationId), contains('applicationId')),
    );
    expect(
      File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync(),
      contains('PRODUCT_BUNDLE_IDENTIFIER = $applicationId;'),
    );
    expect(
      File('macos/Runner/Configs/AppInfo.xcconfig').readAsStringSync(),
      allOf(
        contains('PRODUCT_NAME = $displayName'),
        contains('EXECUTABLE_NAME = $packageName'),
        contains('PRODUCT_BUNDLE_IDENTIFIER = $applicationId'),
      ),
    );
    expect(
      File('linux/CMakeLists.txt').readAsStringSync(),
      allOf(contains(packageName), contains(applicationId)),
    );
    expect(
      File('windows/CMakeLists.txt').readAsStringSync(),
      contains(packageName),
    );
  });
}
