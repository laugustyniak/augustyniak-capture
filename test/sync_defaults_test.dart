import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:augustyniak_capture/core/sync/sync_defaults.dart';

/// [SyncDefaults] is the only door build-time sync credentials come through,
/// and it exists because a working Turso JWT and an R2 secret were once inlined
/// in four files of a public repository at once.
void main() {
  group('SyncDefaults', () {
    test('a build with no defines has no sync configured', () {
      // The normal state, and the one the whole design rests on: absent means
      // absent, so the Config tab or a QR pairing supplies the values instead.
      expect(SyncDefaults.tursoDbUrl, isNull);
      expect(SyncDefaults.tursoAuthToken, isNull);
      expect(SyncDefaults.r2Endpoint, isNull);
      expect(SyncDefaults.r2Bucket, isNull);
      expect(SyncDefaults.r2AccessKeyId, isNull);
      expect(SyncDefaults.r2SecretAccessKey, isNull);
    });

    test('an unset define is null, never the empty string', () {
      // Call sites chain `??`, so '' would read as a configured endpoint and
      // produce a request to nowhere instead of falling through to the user's
      // own settings.
      expect(SyncDefaults.tursoDbUrl, isNot(''));
      expect(SyncDefaults.r2Bucket, isNot(''));
    });

    test('Turso needs both halves before it counts as configured', () {
      // A URL without a token, or a token without a URL, reaches nothing — so
      // `hasTurso` is what the seeding path checks rather than either field.
      expect(SyncDefaults.hasTurso, isFalse);
    });

    test('every define name is documented in CLAUDE.md', () {
      // The rot this guards against is the one already found twice today: the
      // documentation kept naming settings.json and the system keyring long
      // after both had moved. A define nobody can name is a define nobody can
      // use, and renaming one here would silently make the instructions wrong.
      final String source = File(
        'lib/core/sync/sync_defaults.dart',
      ).readAsStringSync();
      final String guide = File('CLAUDE.md').readAsStringSync();

      final Iterable<String> names = RegExp(
        r"String\.fromEnvironment\('([A-Z0-9_]+)'\)",
      ).allMatches(source).map((RegExpMatch m) => m.group(1)!);

      expect(names, isNotEmpty, reason: 'no defines found to check');
      for (final String name in names) {
        expect(guide, contains(name), reason: '$name is undocumented');
      }
    });
  });
}
