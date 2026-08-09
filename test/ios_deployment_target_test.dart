import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Pins the iOS deployment target high enough for the plugins in `pubspec.yaml`.
///
/// **This is the check CI performs, moved to where it costs a second instead of
/// six minutes.** `mobile_scanner` 6.x declared `s.platform = :ios, '15.5.0'`
/// while the project shipped 13.0, so `pod install` refused to resolve and the
/// Apple job failed on every push while analyze, test, Windows and macOS all
/// stayed green. Nothing in the Dart suite could see it, and nothing locally
/// either — `ios/` is partial here, so it only ever appeared on a runner.
///
/// `mobile_scanner` 7.x dropped GoogleMLKit for native APIs and asks for 12.0,
/// so the floor went back to the Flutter template's 13.0 and iPhones older than
/// the 6s are supported again. The test stays because the failure mode has not:
/// any plugin can raise its own floor, and `flutter create` resets these files
/// to the template.
void main() {
  /// The highest `ios.deployment_target` among this project's plugins. Raise it
  /// when a dependency demands more; the CI error names the plugin that does.
  const double required = 13.0;

  group('iOS deployment target', () {
    test('the Xcode project targets a version the plugins accept', () {
      final String project = File(
        'ios/Runner.xcodeproj/project.pbxproj',
      ).readAsStringSync();

      final Iterable<RegExpMatch> found = RegExp(
        r'IPHONEOS_DEPLOYMENT_TARGET = ([0-9.]+);',
      ).allMatches(project);

      expect(found, isNotEmpty, reason: 'no deployment target declared');
      for (final RegExpMatch m in found) {
        final double value = double.parse(m.group(1)!);
        expect(
          value,
          greaterThanOrEqualTo(required),
          reason:
              'IPHONEOS_DEPLOYMENT_TARGET is ${m.group(1)}, below the $required '
              'the plugins require — pod install will refuse',
        );
      }
    });

    test('the Podfile pins the same floor, uncommented', () {
      // CocoaPods resolves against the Podfile, not the Xcode project, so a
      // commented-out platform line leaves the version to whatever CocoaPods
      // infers — which is how this drifted apart in the first place.
      final String podfile = File('ios/Podfile').readAsStringSync();

      final RegExpMatch? platform = RegExp(
        r"^platform :ios, '([0-9.]+)'",
        multiLine: true,
      ).firstMatch(podfile);

      expect(
        platform,
        isNotNull,
        reason: 'Podfile has no active `platform :ios` line',
      );
      expect(
        double.parse(platform!.group(1)!),
        greaterThanOrEqualTo(required),
      );
    });

    test('the Podfile and the Xcode project agree', () {
      // The pair drifted apart once already, and it was invisible until a
      // plugin raised its own floor: CocoaPods reads the Podfile, Xcode reads
      // the project, and while nothing demanded more than either declared, two
      // different numbers cost nothing and said nothing.
      final String podfile = File('ios/Podfile').readAsStringSync();
      final String project = File(
        'ios/Runner.xcodeproj/project.pbxproj',
      ).readAsStringSync();

      final String pod = RegExp(
        r"^platform :ios, '([0-9.]+)'",
        multiLine: true,
      ).firstMatch(podfile)!.group(1)!;

      final Set<String> xcode = RegExp(
        r'IPHONEOS_DEPLOYMENT_TARGET = ([0-9.]+);',
      ).allMatches(project).map((RegExpMatch m) => m.group(1)!).toSet();

      expect(
        xcode,
        <String>{pod},
        reason: 'Podfile says $pod, the Xcode project says $xcode',
      );
    });
  });
}
