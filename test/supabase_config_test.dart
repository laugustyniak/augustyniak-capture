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
}
