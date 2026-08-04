import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Pins the application's identity across every platform file that carries it.
///
/// The identity lives in seven places that nothing links together: the pubspec,
/// the root widget, and one build file per platform. A rename that reaches six
/// of them still builds, still passes every other test, and still runs — it
/// simply ships as a different app on the platform it missed. That is not a
/// failure any amount of code review reliably catches, because the values are
/// strings in files nobody reads twice.
///
/// The identifier in particular is not a name but a migration: changing it
/// orphans every install and, on mobile, the container holding their
/// recordings. It was changed once, deliberately
/// (`docs/plans/2026-08-04-augustyniak-capture-rebrand.md`). This test is what
/// makes the next change a decision rather than an accident.
void main() {
  const String displayName = 'Augustyniak Capture';
  const String packageName = 'augustyniak_capture';
  const String applicationId = 'ai.augustyniak.capture';

  String read(String path) => File(path).readAsStringSync();

  test('the Dart package and the window title carry the display name', () {
    expect(read('pubspec.yaml'), startsWith('name: $packageName'));
    expect(read('lib/app/app.dart'), contains(displayName));
  });

  test('every platform declares the same application identifier', () {
    // Android. The Kotlin package has to follow the namespace, or the activity
    // the manifest names relatively cannot be resolved.
    expect(read('android/app/build.gradle.kts'), contains(applicationId));
    expect(
      File(
        'android/app/src/main/kotlin/ai/augustyniak/capture/MainActivity.kt',
      ).existsSync(),
      isTrue,
      reason: 'the Kotlin package must match the Android namespace',
    );

    // iOS. Matched with the trailing semicolon so this sees the app target
    // rather than the `.RunnerTests` bundle id that shares the prefix.
    expect(
      read('ios/Runner.xcodeproj/project.pbxproj'),
      contains('PRODUCT_BUNDLE_IDENTIFIER = $applicationId;'),
    );

    // macOS. EXECUTABLE_NAME is part of the contract rather than a detail: the
    // display name contains a space, so without it the binary does too and
    // TEST_HOST points at a bundle that is never built.
    final String macos = read('macos/Runner/Configs/AppInfo.xcconfig');
    expect(macos, contains('PRODUCT_NAME = $displayName'));
    expect(macos, contains('EXECUTABLE_NAME = $packageName'));
    expect(macos, contains('PRODUCT_BUNDLE_IDENTIFIER = $applicationId'));

    // Linux and Windows.
    final String linux = read('linux/CMakeLists.txt');
    expect(linux, contains(packageName));
    expect(linux, contains(applicationId));
    expect(read('windows/CMakeLists.txt'), contains(packageName));
  });
}
