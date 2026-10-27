import 'dart:io';

import 'package:augustyniak_capture/core/security/app_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// The mobile at-rest decisions (#300), pinned the way `rebrand_test.dart` pins
/// the identifier: each lives in a platform file or a plugin option that no
/// other test can reach, and the platform default is the wrong answer for all
/// of them. `docs/platform-setup.md` carries the reasoning.
void main() {
  String read(String path) => File(path).readAsStringSync();

  group('Android backup', () {
    const String manifest = 'android/app/src/main/AndroidManifest.xml';
    const String rules = 'android/app/src/main/res/xml';

    /// The `<application>` element alone, so a comment mentioning the attribute
    /// or the attribute on the wrong element cannot satisfy the pin.
    String application() {
      final String source = read(manifest);
      final int start = source.indexOf('<application');
      expect(start, isNonNegative);
      return source.substring(start, source.indexOf('>', start));
    }

    test('the OS backup is off', () {
      // The default is "true", and it puts the token database, the recordings
      // and the clipboard history into Google auto-backup. The app's own
      // backup feature is the documented answer to a reinstall.
      expect(application(), contains('android:allowBackup="false"'));
    });

    test('both rule files are declared and exclude every domain', () {
      final String element = application();
      expect(
        element,
        contains('android:fullBackupContent="@xml/backup_rules"'),
      );
      expect(
        element,
        contains('android:dataExtractionRules="@xml/data_extraction_rules"'),
      );

      const List<String> domains = <String>[
        'root',
        'file',
        'database',
        'sharedpref',
        'external',
      ];
      final String legacy = read('$rules/backup_rules.xml');
      final String modern = read('$rules/data_extraction_rules.xml');
      for (final String domain in domains) {
        expect(
          legacy,
          contains('<exclude domain="$domain" />'),
          reason: domain,
        );
        // Once per section: cloud backup and device-to-device transfer.
        expect(
          '<exclude domain="$domain" />'.allMatches(modern),
          hasLength(2),
          reason: domain,
        );
      }
      expect(legacy, isNot(contains('<include')));
      expect(modern, isNot(contains('<include')));
    });
  });

  group('AppSecureStorage', () {
    test('Android keeps the master key in EncryptedSharedPreferences', () {
      // The plugin default is its own cipher over plain SharedPreferences, a
      // file that travels with any copy of the app's data.
      expect(
        AppSecureStorage.androidOptions.toMap()['encryptedSharedPreferences'],
        'true',
      );
    });

    test('iOS keychain items stay on this device', () {
      // The plugin default, `unlocked`, migrates inside an encrypted backup;
      // the master key moving with the database it opens defeats sealing.
      expect(
        AppSecureStorage.iosOptions.toMap()['accessibility'],
        'first_unlock_this_device',
      );
    });

    test('the shared instance carries all three platform options', () {
      expect(
        AppSecureStorage.instance.aOptions,
        AppSecureStorage.androidOptions,
      );
      expect(AppSecureStorage.instance.iOptions, AppSecureStorage.iosOptions);
      expect(AppSecureStorage.instance.mOptions, AppSecureStorage.macOsOptions);
    });
  });
}
