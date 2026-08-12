import 'dart:convert';

import 'package:augustyniak_capture/core/sync/sync_endpoint.dart';
import 'package:augustyniak_capture/core/sync/sync_pairing_payload.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pairing hands a stranger's URL and token to a client that then uploads every
/// capture, so the two questions here are "is this address safe to send a
/// bearer token to" and "did the user agree to this one".
///
/// The scanner used to answer neither: any QR code carrying the right `type`
/// field was applied and pulled from on sight, with no confirmation and no
/// scheme check, which made one poster enough to repoint the whole queue at
/// somebody else's database.
void main() {
  group('SyncEndpoint.normalize', () {
    test('accepts the two schemes Turso actually speaks', () {
      expect(
        SyncEndpoint.normalize('libsql://db-me.turso.io'),
        'libsql://db-me.turso.io',
      );
      expect(
        SyncEndpoint.normalize('https://db-me.turso.io'),
        'https://db-me.turso.io',
      );
    });

    test('refuses http, which would send the bearer token in the clear', () {
      // The whole point of the check: the pipeline call carries
      // `Authorization: Bearer …` plus every transcript in the batch.
      expect(SyncEndpoint.normalize('http://db-me.turso.io'), isNull);
    });

    test('refuses a scheme that is not a network address at all', () {
      expect(SyncEndpoint.normalize('file:///etc/passwd'), isNull);
      expect(SyncEndpoint.normalize('javascript:alert(1)'), isNull);
    });

    test('refuses an address with no scheme or no host', () {
      expect(SyncEndpoint.normalize('db-me.turso.io'), isNull);
      expect(SyncEndpoint.normalize('libsql://'), isNull);
    });

    test('blank and null are unconfigured, not invalid', () {
      expect(SyncEndpoint.normalize(null), isNull);
      expect(SyncEndpoint.normalize('   '), isNull);
    });

    test('surrounding whitespace is trimmed rather than rejected', () {
      // A pasted URL routinely carries a trailing newline.
      expect(
        SyncEndpoint.normalize('  libsql://db-me.turso.io \n'),
        'libsql://db-me.turso.io',
      );
    });

    test('the host is what a confirmation prompt has to show', () {
      expect(SyncEndpoint.hostOf('libsql://db-me.turso.io'), 'db-me.turso.io');
      expect(SyncEndpoint.hostOf('nonsense'), isNull);
    });
  });

  group('SyncPairingPayload.parse', () {
    String code(Map<String, dynamic> overrides) => jsonEncode(<String, dynamic>{
      'type': 'augustyniak_sync_v1',
      'tursoDbUrl': 'libsql://db-me.turso.io',
      'tursoAuthToken': 'token-abc',
      'r2Endpoint': 'https://account.r2.cloudflarestorage.com',
      'r2Bucket': 'captures',
      'r2AccessKeyId': 'key-id',
      'r2SecretAccessKey': 'key-secret',
      ...overrides,
    });

    test('reads a well-formed pairing code', () {
      final SyncPairingPayload? payload = SyncPairingPayload.parse(
        code(<String, dynamic>{}),
      );

      expect(payload, isNotNull);
      expect(payload!.tursoDbUrl, 'libsql://db-me.turso.io');
      expect(payload.tursoAuthToken, 'token-abc');
      expect(payload.r2Bucket, 'captures');
      // What the confirmation sheet puts in front of the user before anything
      // is written: a token is unreadable, a host is not.
      expect(payload.host, 'db-me.turso.io');
    });

    test('refuses a database URL that is not https or libsql', () {
      expect(
        SyncPairingPayload.parse(
          code(<String, dynamic>{'tursoDbUrl': 'http://db-me.turso.io'}),
        ),
        isNull,
      );
    });

    test('refuses a code with no token — it configures nothing usable', () {
      expect(
        SyncPairingPayload.parse(code(<String, dynamic>{'tursoAuthToken': ''})),
        isNull,
      );
    });

    test('refuses an R2 endpoint that is not https', () {
      // The R2 secret access key rides the same pairing code.
      expect(
        SyncPairingPayload.parse(
          code(<String, dynamic>{'r2Endpoint': 'http://attacker.example'}),
        ),
        isNull,
      );
    });

    test('an absent R2 half is allowed — Turso alone is a valid pairing', () {
      final SyncPairingPayload? payload = SyncPairingPayload.parse(
        jsonEncode(<String, dynamic>{
          'type': 'augustyniak_sync_v1',
          'tursoDbUrl': 'libsql://db-me.turso.io',
          'tursoAuthToken': 'token-abc',
        }),
      );

      expect(payload, isNotNull);
      expect(payload!.r2Bucket, isNull);
      expect(payload.hasR2, isFalse);
    });

    test('refuses anything that is not this app\'s pairing code', () {
      expect(SyncPairingPayload.parse('https://example.com'), isNull);
      expect(SyncPairingPayload.parse('{'), isNull);
      expect(
        SyncPairingPayload.parse(code(<String, dynamic>{'type': 'other_v1'})),
        isNull,
      );
    });
  });
}
