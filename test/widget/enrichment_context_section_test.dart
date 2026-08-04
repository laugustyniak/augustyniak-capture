import 'dart:io';

import 'package:audivoa_core/features/projects/domain/project.dart';
import 'package:audivoa_core/features/settings/presentation/enrichment_context_section.dart';
import 'package:audivoa_core/features/settings/presentation/settings_controller.dart';
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

  Future<void> pumpSection(
    WidgetTester tester, {
    required List<Project> projects,
  }) async {
    final SettingsController controller = buildSettingsController();
    await controller.initialize();
    await tester.pumpWidget(
      hostTab(
        () => EnrichmentContextSection(
          controller: controller,
          projects: projects,
        ),
        listenable: controller,
      ),
    );
    await tester.pump();
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
        Project(id: 'p1', name: 'Audivoa', repoPath: repo.path),
      ],
    );
    await settleIo(tester);

    expect(find.text('AUDIVOA'), findsOneWidget);
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
}
