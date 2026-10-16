import 'dart:convert';
import 'dart:io';

import 'package:augustyniak_capture/features/auth/domain/supabase_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SupabaseConfig', () {
    test(
      'accepts the existing NEXT_PUBLIC names when primary names are absent',
      () {
        final SupabaseConfig? config = SupabaseConfig.resolve(
          url: '',
          publishableKey: '',
          nextPublicUrl: 'https://project.supabase.co',
          nextPublicPublishableKey: 'sb_publishable_test',
        );

        expect(config?.url, 'https://project.supabase.co');
        expect(config?.publishableKey, 'sb_publishable_test');
      },
    );

    test('prefers Flutter-specific names over NEXT_PUBLIC aliases', () {
      final SupabaseConfig? config = SupabaseConfig.resolve(
        url: 'https://flutter.supabase.co',
        publishableKey: 'sb_publishable_flutter',
        nextPublicUrl: 'https://next.supabase.co',
        nextPublicPublishableKey: 'sb_publishable_next',
      );

      expect(config?.url, 'https://flutter.supabase.co');
      expect(config?.publishableKey, 'sb_publishable_flutter');
    });

    test('is absent when both build-time values are absent', () {
      expect(SupabaseConfig.parse(url: '', publishableKey: ''), isNull);
    });

    test('is absent when only one build-time value is present', () {
      expect(
        SupabaseConfig.parse(
          url: 'https://capture.supabase.co',
          publishableKey: '',
        ),
        isNull,
      );
      expect(
        SupabaseConfig.parse(url: '', publishableKey: 'sb_publishable_test'),
        isNull,
      );
    });

    test('accepts an https Supabase endpoint', () {
      final SupabaseConfig? config = SupabaseConfig.parse(
        url: ' https://capture.supabase.co/ ',
        publishableKey: ' sb_publishable_test ',
      );

      expect(config, isNotNull);
      expect(config!.url, 'https://capture.supabase.co');
      expect(config.publishableKey, 'sb_publishable_test');
    });

    test('accepts http only for local development', () {
      expect(
        SupabaseConfig.parse(
          url: 'http://127.0.0.1:54321',
          publishableKey: 'local-key',
        ),
        isNotNull,
      );
      expect(
        SupabaseConfig.parse(
          url: 'http://supabase.example.com',
          publishableKey: 'public-key',
        ),
        isNull,
      );
    });

    test('rejects credentials embedded in the endpoint', () {
      expect(
        SupabaseConfig.parse(
          url: 'https://user:password@capture.supabase.co',
          publishableKey: 'public-key',
        ),
        isNull,
      );
    });

    test('rejects a server-side Supabase secret key', () {
      expect(
        SupabaseConfig.parse(
          url: 'https://capture.supabase.co',
          publishableKey: 'sb_secret_must_stay_on_the_server',
        ),
        isNull,
      );
    });

    test('every define name is documented in CLAUDE.md', () {
      final String source = File(
        'lib/features/auth/domain/supabase_config.dart',
      ).readAsStringSync();
      final String guide = File('CLAUDE.md').readAsStringSync();
      final Iterable<String> names = RegExp(
        r"String\.fromEnvironment\(\s*'([A-Z0-9_]+)'",
      ).allMatches(source).map((RegExpMatch match) => match.group(1)!);

      expect(names, isNotEmpty);
      for (final String name in names) {
        expect(guide, contains(name), reason: '$name is undocumented');
      }
    });
  });

  group('SupabaseConfig key checks', () {
    // Built at runtime: a JWT literal in a file trips the pre-commit hook and
    // the CI secret scan, and these are not secrets anyway.
    String b64(Object v) =>
        base64Url.encode(utf8.encode(jsonEncode(v))).replaceAll('=', '');
    String jwt(Map<String, Object?> payload) =>
        '${b64(<String, Object?>{'alg': 'HS256', 'typ': 'JWT'})}'
        '.${b64(payload)}.${'x' * 43}';

    const String url = 'https://capture.supabase.co';

    String? issueOf(String key) =>
        SupabaseConfig.parseIssue(url: url, publishableKey: key);
    SupabaseConfig? parseKey(String key) =>
        SupabaseConfig.parse(url: url, publishableKey: key);

    test('accepts an anon JWT', () {
      final String key = jwt(<String, Object?>{'role': 'anon'});
      expect(parseKey(key), isNotNull);
      expect(issueOf(key), isNull);
    });

    test('refuses a service_role JWT without echoing it', () {
      final String payload = b64(<String, Object?>{'role': 'service_role'});
      final String key = '${b64(<String, Object?>{'alg': 'HS256'})}'
          '.$payload.${'x' * 43}';
      expect(parseKey(key), isNull);
      final String? issue = issueOf(key);
      expect(issue, contains('service_role'));
      expect(issue, isNot(contains(key)));
      expect(issue, isNot(contains(payload)));
    });

    test('refuses an authenticated JWT', () {
      final String key = jwt(<String, Object?>{'role': 'authenticated'});
      expect(parseKey(key), isNull);
      expect(
        issueOf(key),
        'SUPABASE_PUBLISHABLE_KEY is a authenticated JWT; use the anon or '
        'publishable key.',
      );
    });

    test('does not render an odd role claim', () {
      final String key = jwt(<String, Object?>{'role': 'bad role!'});
      expect(parseKey(key), isNull);
      expect(issueOf(key), contains('a non-anon JWT'));
      expect(issueOf(key), isNot(contains('bad role')));
    });

    test('accepts a publishable key', () {
      expect(parseKey('sb_publishable_test'), isNotNull);
      expect(issueOf('sb_publishable_test'), isNull);
    });

    test('refuses a secret key without echoing it', () {
      const String key = 'sb_secret_abcdef123456';
      expect(parseKey(key), isNull);
      final String? issue = issueOf(key);
      expect(issue, contains('server-side secret key'));
      expect(issue, isNot(contains('abcdef')));
    });

    test('refuses malformed eyJ strings with the matching line', () {
      const String unreadable =
          'SUPABASE_PUBLISHABLE_KEY looks like a JWT but its payload could '
          'not be read.';
      final String twoParts = 'eyJhbGciOiJIUzI1NiJ9.${b64(<String>['a'])}';
      final String badPayload = 'eyJhbGciOiJIUzI1NiJ9.!!!notbase64!!!.sig';
      final String listPayload =
          '${b64(<String, Object?>{'alg': 'x'})}.${b64(<String>['a'])}.sig';
      for (final String key in <String>[twoParts, badPayload, listPayload]) {
        expect(parseKey(key), isNull, reason: key);
        expect(issueOf(key), unreadable, reason: key);
      }
      final String noRole = jwt(<String, Object?>{'iss': 'supabase'});
      expect(parseKey(noRole), isNull);
      expect(
        issueOf(noRole),
        'SUPABASE_PUBLISHABLE_KEY is a JWT with no role claim; use the anon '
        'or publishable key.',
      );
    });

    test('reports url and pairing issues', () {
      expect(
        SupabaseConfig.parseIssue(url: url, publishableKey: ''),
        'SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY must both be set.',
      );
      expect(
        SupabaseConfig.parseIssue(url: 'https://a.co/x', publishableKey: 'k'),
        'SUPABASE_URL must be the bare project URL (https://<ref>.supabase.co).',
      );
      expect(
        SupabaseConfig.parseIssue(url: 'http://a.co', publishableKey: 'k'),
        'SUPABASE_URL must use https (http is allowed for localhost only).',
      );
      expect(SupabaseConfig.parseIssue(url: '', publishableKey: ''), isNull);
    });

    test('resolveIssue names the pair the user set first', () {
      final String bad = jwt(<String, Object?>{'role': 'service_role'});
      expect(
        SupabaseConfig.resolveIssue(
          url: '',
          publishableKey: '',
          nextPublicUrl: url,
          nextPublicPublishableKey: bad,
        ),
        contains('service_role'),
      );
      expect(
        SupabaseConfig.resolveIssue(
          url: '',
          publishableKey: '',
          nextPublicUrl: '',
          nextPublicPublishableKey: '',
        ),
        isNull,
      );
      // The fallback still builds a config from the valid NEXT_PUBLIC pair,
      // while the issue names the Flutter pair that was set first.
      expect(
        SupabaseConfig.resolve(
          url: url,
          publishableKey: bad,
          nextPublicUrl: url,
          nextPublicPublishableKey: 'sb_publishable_ok',
        ),
        isNotNull,
      );
      expect(
        SupabaseConfig.resolveIssue(
          url: url,
          publishableKey: bad,
          nextPublicUrl: url,
          nextPublicPublishableKey: 'sb_publishable_ok',
        ),
        contains('service_role'),
      );
    });

    test('environmentIssue is null without defines', () {
      expect(SupabaseConfig.environmentIssue(), isNull);
    });
  });
}
