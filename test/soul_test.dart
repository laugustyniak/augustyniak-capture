import 'dart:io';

import 'package:augustyniak_capture/features/enrichment/data/composed_enrichment_context_source.dart';
import 'package:augustyniak_capture/features/enrichment/data/soul_reader.dart';
import 'package:augustyniak_capture/features/enrichment/domain/enrichment_context.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_priority.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/settings/domain/app_settings.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_row_codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('soul_'));
  tearDown(() => dir.deleteSync(recursive: true));

  String soulFile(String text) {
    final File file = File('${dir.path}/SOUL.md')..writeAsStringSync(text);
    return file.path;
  }

  group('SoulReader', () {
    const SoulReader reader = SoulReader();

    test('no path means the typed profile is the soul', () async {
      final ResolvedSoul soul = await reader.resolve(path: '  ', typed: 'T');

      expect(soul.origin, SoulOrigin.typed);
      expect(soul.text, 'T');
      expect(soul.origin.isFallback, isFalse);
    });

    test('a readable file replaces the typed profile', () async {
      final ResolvedSoul soul = await reader.resolve(
        path: soulFile('Goal: ship the beta.'),
        typed: 'T',
      );

      expect(soul.origin, SoulOrigin.file);
      expect(soul.text, 'Goal: ship the beta.');
      expect(soul.fileName, 'SOUL.md');
    });

    test('a missing file falls back to the typed profile', () async {
      final ResolvedSoul soul = await reader.resolve(
        path: '${dir.path}/nope.md',
        typed: 'T',
      );

      expect(soul.origin, SoulOrigin.missing);
      expect(soul.text, 'T');
      expect(soul.origin.isFallback, isTrue);
    });

    test('a blank file falls back, and is not mistaken for missing', () async {
      final ResolvedSoul soul = await reader.resolve(
        path: soulFile('  \n '),
        typed: 'T',
      );

      expect(soul.origin, SoulOrigin.empty);
      expect(soul.text, 'T');
    });

    test('a directory is unreadable, not missing, and never throws', () async {
      final ResolvedSoul soul = await reader.resolve(
        path: dir.path,
        typed: 'T',
      );

      expect(soul.origin, SoulOrigin.unreadable);
      expect(soul.text, 'T');
      expect(soul.error, isNotNull);
    });

    test('a file past the ceiling reports that it will be truncated', () async {
      final ResolvedSoul long = await reader.resolve(
        path: soulFile('x' * (EnrichmentContext.maxProfileChars + 1)),
        typed: 'T',
      );
      expect(long.truncated, isTrue);

      final ResolvedSoul short = await reader.resolve(
        path: soulFile('x'),
        typed: 'T',
      );
      expect(short.truncated, isFalse);
    });
  });

  group('ComposedEnrichmentContextSource with a soul file', () {
    ComposedEnrichmentContextSource source({
      required String? path,
      String typed = 'typed profile',
    }) => ComposedEnrichmentContextSource(
      profile: () => typed,
      soulPath: () => path,
      projectById: (String _) => null,
    );

    test('the file is the profile, and the log names it', () async {
      final EnrichmentContext context = await source(
        path: soulFile('Goal: ship the beta.'),
      ).contextFor(null);

      expect(context.profile, 'Goal: ship the beta.');
      expect(context.profileSource, 'SOUL.md');
      expect(context.sourceSummary, 'SOUL.md');
    });

    test('a missing file costs the file, never the profile', () async {
      final EnrichmentContext context = await source(
        path: '${dir.path}/SOUL.md',
      ).contextFor(null);

      expect(context.profile, 'typed profile');
      expect(context.profileSource, isNull);
      // The fallback is visible in the one log line that names the context.
      expect(context.sourceSummary, 'profile (SOUL.md missing)');
    });

    test('the file is re-read on every capture', () async {
      final String path = soulFile('first');
      final ComposedEnrichmentContextSource s = source(path: path);
      expect((await s.contextFor(null)).profile, 'first');

      File(path).writeAsStringSync('second');
      expect((await s.contextFor(null)).profile, 'second');
    });

    test('without a soul path it behaves exactly as before', () async {
      final EnrichmentContext context = await source(
        path: null,
      ).contextFor(null);

      expect(context.profile, 'typed profile');
      expect(context.sourceSummary, 'profile');
    });
  });

  group('EnrichmentContext.profileBasis', () {
    test('is a stable short fingerprint of the profile as sent', () {
      const EnrichmentContext a = EnrichmentContext(profile: 'Goal: beta.');
      const EnrichmentContext same = EnrichmentContext(
        profile: '  Goal: beta.  ',
      );
      const EnrichmentContext other = EnrichmentContext(profile: 'Goal: v2.');

      expect(a.profileBasis, hasLength(8));
      expect(a.profileBasis, same.profileBasis);
      expect(a.profileBasis, isNot(other.profileBasis));
    });

    test('is null when no profile is sent', () {
      expect(const EnrichmentContext(profile: '   ').profileBasis, isNull);
      expect(EnrichmentContext.none.profileBasis, isNull);
    });
  });

  group('AppSettings.soulPath', () {
    test('round-trips, and stays out of the JSON while unset', () {
      const AppSettings set = AppSettings(soulPath: '/Users/me/SOUL.md');
      expect(AppSettings.fromJson(set.toJson()).soulPath, '/Users/me/SOUL.md');
      expect(AppSettings.empty.toJson().containsKey('soulPath'), isFalse);
    });

    test('a non-string value degrades to unset', () {
      expect(
        AppSettings.fromJson(<String, dynamic>{'soulPath': 7}).soulPath,
        isNull,
      );
    });

    test('copyWith clears it', () {
      const AppSettings set = AppSettings(soulPath: '/x/SOUL.md');
      expect(set.copyWith(clearSoulPath: true).soulPath, isNull);
      expect(set.copyWith(timerMinutes: 5).soulPath, '/x/SOUL.md');
    });
  });

  group('Recording.priorityBasis', () {
    Recording ranked({String? basis}) => Recording(
      id: 'r',
      filePath: '/tmp/r.m4a',
      createdAt: DateTime.utc(2026, 10, 5),
      durationMs: 0,
      status: RecordingStatus.completed,
      priority: CapturePriority.p1,
      priorityBasis: basis,
    );

    test('round-trips, and stays out of the JSON while absent', () {
      expect(
        Recording.fromJson(ranked(basis: 'ab12cd34').toJson()).priorityBasis,
        'ab12cd34',
      );
      expect(ranked().toJson().containsKey('priorityBasis'), isFalse);
    });

    test('survives a sync row', () {
      final Recording original = ranked(basis: 'ab12cd34');
      expect(
        SyncRowCodec.recordingFromRow(
          SyncRowCodec.recording(original),
          local: original,
        )?.priorityBasis,
        'ab12cd34',
      );
    });
  });
}
