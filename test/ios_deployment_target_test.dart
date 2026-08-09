import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Pins the iOS deployment target high enough for the plugins in `pubspec.yaml`.
///
/// **This is the check that CI already performs, moved to where it costs a
/// second instead of six minutes.** `mobile_scanner` (the QR pairing scanner)
/// declares `s.platform = :ios, '15.5.0'`; the project shipped 13.0, so
/// `pod install` refused to resolve and the "Build iOS simulator" job failed on
/// every push while analyze, test, Windows and macOS all stayed green. Nothing
/// in the Dart suite could see it, and nothing locally either — `ios/` is
/// partial in this repo, so the failure only ever appeared on a runner.
///
/// Raising the floor is a product decision, not a formality: iOS 15.5 drops
/// everything older than the iPhone 6s. It is recorded here so the next person
/// to lower it, or to regenerate `ios/` with `flutter create` (which resets the
/// value to the template's), finds out before pushing.
void main() {
  /// The highest `ios.deployment_target` among this project's plugins.
  /// Bump when a dependency demands more — the CI error names the plugin.
  const double required = 15.5;

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
              'that mobile_scanner requires — pod install will refuse',
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
  });
}
