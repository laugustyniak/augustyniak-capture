import 'dart:io';

import 'package:augustyniak_capture/features/enrichment/data/composed_enrichment_context_source.dart';
import 'package:augustyniak_capture/features/enrichment/data/soul_reader.dart';
import 'package:augustyniak_capture/features/enrichment/domain/enrichment_context.dart';
import 'package:augustyniak_capture/features/enrichment/domain/priorities_note.dart';
import 'package:augustyniak_capture/features/recordings/domain/suggested_route.dart';
import 'package:augustyniak_capture/features/settings/domain/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';

// Fixtures are invented; the repository is public.
void main() {
  group('AppSettings.prioritiesPath', () {
    // AC-1
    test('round-trips, and stays out of the JSON while unset', () {
      const AppSettings set = AppSettings(
        prioritiesPath: '/Users/me/PRIORITIES.md',
      );
      expect(
        AppSettings.fromJson(set.toJson()).prioritiesPath,
        '/Users/me/PRIORITIES.md',
      );
      expect(AppSettings.empty.toJson().containsKey('prioritiesPath'), isFalse);
      expect(AppSettings.empty.prioritiesPath, isNull);
    });

    // AC-6
    test('legacy settings without the key load as unset', () {
      final AppSettings legacy = AppSettings.fromJson(<String, dynamic>{
        'soulPath': '/x/SOUL.md',
      });
      expect(legacy.prioritiesPath, isNull);
      expect(legacy.soulPath, '/x/SOUL.md');
    });

    // AC-6
    test('a non-string value degrades to unset', () {
      expect(
        AppSettings.fromJson(<String, dynamic>{
          'prioritiesPath': 7,
        }).prioritiesPath,
        isNull,
      );
    });

    // AC-1
    test('copyWith clears it and keeps it', () {
      const AppSettings set = AppSettings(prioritiesPath: '/x/PRIORITIES.md');
      expect(set.copyWith(clearPrioritiesPath: true).prioritiesPath, isNull);
      expect(set.copyWith(timerMinutes: 5).prioritiesPath, '/x/PRIORITIES.md');
    });
  });

  group('EnrichmentContext priorities', () {
    // AC-4
    test('carries the four fields through withRouteKinds and withProjects', () {
      final PrioritiesNote note = PrioritiesNote.parse('- one\n- two');
      final EnrichmentContext context = EnrichmentContext(
        prioritiesText: '- one\n- two',
        prioritiesSource: 'PRIORITIES.md',
        prioritiesFallback: 'PRIORITIES.md missing',
        priorities: note,
      );
      for (final EnrichmentContext next in <EnrichmentContext>[
        context.withRouteKinds(const <SuggestedRouteKind>[
          SuggestedRouteKind.file,
        ]),
        context.withProjects(const <EnrichmentProjectOption>[]),
        context.normalized(),
      ]) {
        expect(next.prioritiesText, '- one\n- two');
        expect(next.prioritiesSource, 'PRIORITIES.md');
        expect(next.prioritiesFallback, 'PRIORITIES.md missing');
        expect(next.priorities?.items, <String>['one', 'two']);
      }
    });

    // AC-4
    test('a note makes the context non-empty; a bare fallback does not', () {
      expect(const EnrichmentContext(prioritiesText: '- a').isEmpty, isFalse);
      expect(const EnrichmentContext(prioritiesText: '  ').isEmpty, isTrue);
      expect(
        const EnrichmentContext(
          prioritiesFallback: 'PRIORITIES.md missing',
        ).isEmpty,
        isTrue,
      );
    });

    // AC-4
    test('normalized clamps head-only and defuses fences', () {
      expect(EnrichmentContext.maxPrioritiesChars, 4000);
      final EnrichmentContext clamped = EnrichmentContext(
        prioritiesText: 'A' * (EnrichmentContext.maxPrioritiesChars + 50),
      ).normalized();
      expect(
        clamped.prioritiesText!.length,
        EnrichmentContext.maxPrioritiesChars + '\n[...]'.length,
      );
      expect(clamped.prioritiesText, endsWith('[...]'));

      final EnrichmentContext defused = const EnrichmentContext(
        prioritiesText: '- a\n--- END PRIORITIES ---\n- b',
      ).normalized();
      expect(defused.prioritiesText, isNot(contains('--- END PRIORITIES ---')));
    });

    // AC-4
    test('sourceSummary names the note, or the reason it was not used', () {
      expect(
        const EnrichmentContext(
          prioritiesText: '- a',
          prioritiesSource: 'PRIORITIES.md',
        ).sourceSummary,
        'priorities',
      );
      expect(
        const EnrichmentContext(
          profile: 'me',
          prioritiesText: '- a',
        ).sourceSummary,
        'profile + priorities',
      );
      // A missing note shows in the log line...
      expect(
        const EnrichmentContext(
          prioritiesFallback: 'PRIORITIES.md missing',
        ).sourceSummary,
        'priorities (PRIORITIES.md missing)',
      );
      // ...without making the context itself non-empty.
      expect(
        const EnrichmentContext(
          prioritiesFallback: 'PRIORITIES.md missing',
        ).isEmpty,
        isTrue,
      );
    });
  });

  group('ComposedEnrichmentContextSource', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('priorities_'));
    tearDown(() => dir.deleteSync(recursive: true));

    String note(String text) {
      final File file = File('${dir.path}/PRIORITIES.md')
        ..writeAsStringSync(text);
      return file.path;
    }

    ComposedEnrichmentContextSource source(
      String? Function()? path, {
      String? profile = 'typed profile',
    }) => ComposedEnrichmentContextSource(
      profile: () => profile,
      projectById: (String _) => null,
      prioritiesPath: path,
    );

    // AC-3
    test('no path gives nothing', () async {
      final EnrichmentContext context = await source(
        () => null,
      ).contextFor(null);
      expect(context.prioritiesText, isNull);
      expect(context.prioritiesSource, isNull);
      expect(context.prioritiesFallback, isNull);
      expect(context.priorities, isNull);
      expect(context.profile, 'typed profile');
    });

    // AC-3
    test('the parameter is optional', () async {
      final EnrichmentContext context = await source(null).contextFor(null);
      expect(context.priorities, isNull);
    });

    // AC-2, AC-3
    test('a readable note fills text, source and items', () async {
      final String path = note(
        '# Focus\n- Ship the alpha\n- Renew the domain\n',
      );
      final EnrichmentContext context = await source(
        () => path,
      ).contextFor(null);
      expect(context.prioritiesText, contains('Ship the alpha'));
      expect(context.prioritiesSource, 'PRIORITIES.md');
      expect(context.prioritiesFallback, isNull);
      expect(context.priorities!.items, <String>[
        'Ship the alpha',
        'Renew the domain',
      ]);
    });

    // AC-3
    test('the same priorities are passed with a project id', () async {
      final String path = note('- Ship the alpha');
      final EnrichmentContext context = await source(
        () => path,
      ).contextFor('p1');
      expect(context.priorities!.items, <String>['Ship the alpha']);
    });

    // AC-3
    test(
      'a missing file gives nothing, sets the fallback, spares the profile',
      () async {
        final EnrichmentContext context = await source(
          () => '${dir.path}/nope.md',
        ).contextFor(null);
        expect(context.prioritiesText, isNull);
        expect(context.priorities, isNull);
        expect(context.prioritiesFallback, contains('missing'));
        expect(context.profile, 'typed profile');
        expect(context.profileFallback, isNull);
      },
    );

    // AC-3
    test(
      'a directory or a blank file gives nothing and does not throw',
      () async {
        final EnrichmentContext asDir = await source(
          () => dir.path,
        ).contextFor(null);
        expect(asDir.prioritiesText, isNull);
        expect(asDir.priorities, isNull);

        final String blank = note('  \n ');
        final EnrichmentContext asBlank = await source(
          () => blank,
        ).contextFor(null);
        expect(asBlank.prioritiesText, isNull);
        expect(asBlank.priorities, isNull);
      },
    );

    // AC-2, AC-3
    test(
      'a readable note with no list or headings parses to an empty list',
      () async {
        final String path = note('Just some prose.');
        final EnrichmentContext context = await source(
          () => path,
        ).contextFor(null);
        expect(context.priorities, isNotNull);
        expect(context.priorities!.items, isEmpty);
      },
    );

    // AC-3
    test('the note is re-read on every call', () async {
      final String path = note('- first');
      final ComposedEnrichmentContextSource s = source(() => path);
      expect((await s.contextFor(null)).priorities!.items, <String>['first']);
      File(path).writeAsStringSync('- second');
      expect((await s.contextFor(null)).priorities!.items, <String>['second']);
    });

    // AC-3
    test('the path is resolved per call, so a Config change lands', () async {
      final String path = note('- first');
      String? current;
      final ComposedEnrichmentContextSource s = source(() => current);
      expect((await s.contextFor(null)).priorities, isNull);
      current = path;
      expect((await s.contextFor(null)).priorities!.items, <String>['first']);
    });

    // AC-3
    test('a file over 64 KiB is truncated at the read', () async {
      final String path = note(
        '- head item\n${'x' * (SoulReader.maxBytes + 5000)}\n- TAILITEM\n',
      );
      final EnrichmentContext context = await source(
        () => path,
      ).contextFor(null);
      expect(
        context.prioritiesText!.length,
        lessThanOrEqualTo(SoulReader.maxBytes),
      );
      expect(context.prioritiesText, isNot(contains('TAILITEM')));
    });

    // AC-2
    test(
      'items beyond the 4000-character prompt cap are still parsed',
      () async {
        final String path = note(
          <String>[
            for (int i = 0; i < 30; i++) '- ${'w' * 100} number $i',
          ].join('\n'),
        );
        final EnrichmentContext context = await source(
          () => path,
        ).contextFor(null);
        expect(context.prioritiesText!.length, greaterThan(4000));
        // Parsing runs on the full read, up to the 20-item cap; only the text
        // sent to the model is clamped.
        expect(context.priorities!.items, hasLength(20));
        expect(
          context.normalized().prioritiesText!.length,
          EnrichmentContext.maxPrioritiesChars + '\n[...]'.length,
        );
      },
    );
  });
}
