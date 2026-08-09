import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Pins the macOS code-signing arrangement, for the same reason
/// `rebrand_test.dart` pins the bundle identifier: it is platform
/// configuration no Dart test would otherwise touch, and `flutter create
/// --platforms=macos .` rewrites exactly these files back to the template.
///
/// **What breaks when this regresses is invisible from Dart.** An ad-hoc
/// signature has no identity beyond the hash of the binary, so every rebuild is
/// a different application to macOS. The login keychain stores an ACL naming
/// the hashes it trusts and TCC keys the microphone grant the same way, so each
/// build re-prompts and an unapproved one is simply refused — which is how the
/// token master key became unreadable, every request went out with no
/// Authorization header, and providers answered 401 with nothing on screen
/// connecting the two. The keychain ACL had thirteen entries by the time it was
/// diagnosed.
///
/// Signing with a certificate makes the designated requirement name the
/// certificate rather than the hash, so it survives rebuilds. Verified by hand
/// with `codesign -d -r-` across two builds of the same bundle: different
/// `cdhash`, identical requirement.
void main() {
  String read(String path) => File(path).readAsStringSync();

  const String pbxproj = 'macos/Runner.xcodeproj/project.pbxproj';
  const String configs = 'macos/Runner/Configs';

  group('macOS signing identity', () {
    test('the project takes its identity from a variable, not a literal', () {
      final String project = read(pbxproj);

      // The template's ad-hoc literal. Its return means every rebuild is a
      // stranger to the keychain again.
      expect(project, isNot(contains('CODE_SIGN_IDENTITY = "-"')));
      expect(project, contains(r'CODE_SIGN_IDENTITY = "$(LOCAL_SIGN_IDENTITY)"'));
    });

    test('signing is manual, so no Apple development team is demanded', () {
      // Automatic signing with a non-empty identity fails the build outright
      // with "requires a development team" — a self-signed certificate has no
      // team, and this project deliberately has no Apple account.
      final String project = read(pbxproj);

      expect(project, isNot(contains('CODE_SIGN_STYLE = Automatic')));
      expect(project, contains('CODE_SIGN_STYLE = Manual'));
    });

    test('both build configurations default to ad-hoc and opt in optionally',
        () {
      // The opt-in shape, and the reason a clone without a certificate still
      // builds: the variable defaults to the ad-hoc marker, and the file that
      // overrides it is included with `?` so its absence is not an error.
      for (final String name in <String>['Debug', 'Release']) {
        final String config = read('$configs/$name.xcconfig');
        expect(config, contains('LOCAL_SIGN_IDENTITY = -'), reason: name);
        expect(
          config,
          contains('#include? "LocalSigning.xcconfig"'),
          reason: name,
        );
        // Order is load-bearing: the include has to come after the default, or
        // the default would overwrite the machine's identity.
        expect(
          config.indexOf('LOCAL_SIGN_IDENTITY = -') <
              config.indexOf('#include? "LocalSigning.xcconfig"'),
          isTrue,
          reason: name,
        );
      }
    });

    test('the machine-specific file is untracked and has a template', () {
      // Same arrangement as android/key.properties: the real file names one
      // machine's certificate and must never be committed, while the example
      // is what tells the next person the option exists at all.
      expect(File('$configs/LocalSigning.xcconfig.example').existsSync(), isTrue);
      expect(
        read('.gitignore'),
        contains('macos/Runner/Configs/LocalSigning.xcconfig'),
      );
    });
  });
}
