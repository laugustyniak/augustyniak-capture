import 'dart:io';

import 'package:augustyniak_capture/features/projects/data/directory_picker.dart';
import 'package:augustyniak_capture/features/enrichment/domain/enrichment_context.dart';
import 'package:augustyniak_capture/features/enrichment/domain/enrichment_result.dart';
import 'package:augustyniak_capture/features/enrichment/domain/enrichment_service.dart';
import 'package:augustyniak_capture/features/projects/domain/project.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_priority.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/settings/presentation/enrichment_context_section.dart';
import 'package:augustyniak_capture/features/settings/presentation/settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

/// The section is hosted directly rather than through `ConfigTab`, so nothing
/// here scrolls: inside the tab's `ListView` these rows sit below the fold, and
/// a scroll driven while a filesystem probe is in flight is the shape that
/// hangs rather than fails.
void main() {
  // Created synchronously in setUp, outside the fake-async zone: an `await` on
  // real IO from inside a `testWidgets` body never resumes, because nothing
  // pumps the real event loop there. Same reason `capture_test` uses
  // `createTempSync`.
  late Directory repo;

  setUp(() => repo = Directory.systemTemp.createTempSync('enrich_ctx_'));
  tearDown(() => repo.deleteSync(recursive: true));

  /// Work started inside the fake-async zone — the probe reads the real
  /// filesystem — only lands under `runAsync`.
  /// Each round lets exactly one awaited IO call land, and probing a project
  /// chains six of them (stat the directory, stat the file, open, read, close,
  /// then the setState). Four rounds — `capture_test`'s number — silently left
  /// the section still scanning.
  Future<void> settleIo(WidgetTester tester) async {
    for (int i = 0; i < 16; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
  }

  Future<SettingsController> pumpSection(
    WidgetTester tester, {
    required List<Project> projects,
    String? soulPath,
    DirectoryPicker? picker,
    RecordingsController? recordings,
  }) async {
    // Hosted bare, not inside the Config tab's ListView, so the surface has to
    // fit the whole section: the soul file row made it taller than 600 px.
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final SettingsController controller = buildSettingsController();
    await controller.initialize();
    if (soulPath != null) await controller.setSoulPath(soulPath);
    await tester.pumpWidget(
      hostTab(
        () => EnrichmentContextSection(
          controller: controller,
          projects: projects,
          picker: picker ?? _FakeDirectoryPicker(),
          recordings: recordings,
        ),
        listenable: controller,
      ),
    );
    await tester.pump();
    return controller;
  }

  testWidgets('an empty project list scans nothing and settles', (
    WidgetTester tester,
  ) async {
    await pumpSection(tester, projects: const <Project>[]);

    // Settling at all is the assertion: with no projects there is no disk
    // access, so no frame waits on IO the fake-async zone will never run.
    await tester.pumpAndSettle();

    expect(
      find.text('No projects yet — captures carry the profile above only.'),
      findsOneWidget,
    );
    expect(find.text('RESCAN'), findsNothing);
  });

  testWidgets('a project reports the context file found in its repository', (
    WidgetTester tester,
  ) async {
    File(
      '${repo.path}${Platform.pathSeparator}CLAUDE.md',
    ).writeAsStringSync('brief');

    await pumpSection(
      tester,
      projects: <Project>[
        Project(id: 'p1', name: 'Augustyniak Capture', repoPath: repo.path),
      ],
    );
    await settleIo(tester);

    expect(find.text('AUGUSTYNIAK CAPTURE'), findsOneWidget);
    expect(find.text('CLAUDE.md · 5 chars'), findsOneWidget);
  });

  testWidgets('a mistyped repository path is named, not silently empty', (
    WidgetTester tester,
  ) async {
    await pumpSection(
      tester,
      projects: const <Project>[
        Project(
          id: 'p1',
          name: 'Gone',
          repoPath: '/no/such/path',
          description: 'a recorder',
        ),
      ],
    );
    await settleIo(tester);

    // The description would still be sent, but the wrong path is the fact the
    // user can act on — at enrichment time the two are indistinguishable.
    expect(find.text('repository path not found'), findsOneWidget);
  });

  group('soul file', () {
    String soulPath() => '${repo.path}${Platform.pathSeparator}SOUL.md';

    testWidgets('no soul path touches no disk and explains itself', (
      WidgetTester tester,
    ) async {
      await pumpSection(tester, projects: const <Project>[]);
      await tester.pumpAndSettle();

      expect(find.textContaining('Optional. A markdown file'), findsOneWidget);
      expect(find.text('PROFILE'), findsOneWidget);
    });

    testWidgets('a readable file is reported as the soul in use', (
      WidgetTester tester,
    ) async {
      File(soulPath()).writeAsStringSync('Goal: ship the beta.');

      await pumpSection(
        tester,
        projects: const <Project>[],
        soulPath: soulPath(),
      );
      await settleIo(tester);

      expect(find.text('USING SOUL.md · 20 chars'), findsOneWidget);
      // The typed box is still there, and says what it now is.
      expect(find.text('PROFILE · FALLBACK'), findsOneWidget);
    });

    testWidgets('a missing file is named, with the fallback it causes', (
      WidgetTester tester,
    ) async {
      await pumpSection(
        tester,
        projects: const <Project>[],
        soulPath: soulPath(),
      );
      await settleIo(tester);

      expect(
        find.text('SOUL.md MISSING — USING THE PROFILE BELOW'),
        findsOneWidget,
      );
      expect(find.text('PROFILE'), findsOneWidget);
    });

    testWidgets('browse names SOUL.md in the chosen folder', (
      WidgetTester tester,
    ) async {
      final SettingsController controller = await pumpSection(
        tester,
        projects: const <Project>[],
        picker: _FakeDirectoryPicker(chosen: repo.path),
      );

      await tester.tap(find.byTooltip('Choose the folder holding SOUL.md'));
      await settleIo(tester);

      expect(controller.soulPath, soulPath());
    });
  });
  group('re-rank', () {
    const EnrichmentContext soul = EnrichmentContext(profile: 'Goal: beta.');

    testWidgets('names the captures ranked under an older soul and re-ranks', (
      WidgetTester tester,
    ) async {
      final RecordingsController recordings = await buildRecordingsController(
        repo,
        seed: <Recording>[
          makeRecording(id: 'old', transcript: 'call the client').copyWith(
            priority: CapturePriority.p3,
            priorityBasis: 'old00000',
          ),
          makeRecording(id: 'hand', transcript: 'x').copyWith(
            priority: CapturePriority.p1,
          ),
        ],
        enrichmentService: _RankingEnrichment(),
        enrichmentContextSource: _SoulSource(soul),
      );

      await pumpSection(
        tester,
        projects: const <Project>[],
        recordings: recordings,
      );
      await settleIo(tester);

      expect(
        find.text('1 ranked under an older soul · one model call each'),
        findsOneWidget,
      );

      await tester.tap(find.text('RE-RANK 1'));
      await settleIo(tester);

      final Recording old = recordings.recordings.firstWhere(
        (Recording r) => r.id == 'old',
      );
      expect(old.priority, CapturePriority.p0);
      expect(old.priorityBasis, soul.profileBasis);
      expect(find.textContaining('ranked under an older soul'), findsNothing);
    });

    testWidgets('nothing stale means no row at all', (
      WidgetTester tester,
    ) async {
      final RecordingsController recordings = await buildRecordingsController(
        repo,
        enrichmentContextSource: _SoulSource(soul),
      );

      await pumpSection(
        tester,
        projects: const <Project>[],
        recordings: recordings,
      );
      await settleIo(tester);

      expect(find.textContaining('RE-RANK'), findsNothing);
    });
  });
}

class _SoulSource implements EnrichmentContextSource {
  _SoulSource(this.context);
  final EnrichmentContext context;

  @override
  Future<EnrichmentContext> contextFor(String? projectId) async => context;
}

class _RankingEnrichment implements EnrichmentService {
  @override
  Future<EnrichmentResult> enrich(
    String text, {
    EnrichmentContext context = EnrichmentContext.none,
  }) async => const EnrichmentResult(
    priority: CapturePriority.p0,
    priorityReason: 'p0 rule.',
  );
}

class _FakeDirectoryPicker implements DirectoryPicker {
  _FakeDirectoryPicker({this.chosen});

  final String? chosen;

  @override
  bool get isAvailable => true;

  @override
  Future<String?> pick({String? initialDirectory}) async => chosen;
}
