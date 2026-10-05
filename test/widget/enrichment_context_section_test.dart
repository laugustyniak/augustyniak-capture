import 'dart:io';

import 'package:augustyniak_capture/features/projects/data/directory_picker.dart';
import 'package:augustyniak_capture/features/projects/domain/project.dart';
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
}

class _FakeDirectoryPicker implements DirectoryPicker {
  _FakeDirectoryPicker({this.chosen});

  final String? chosen;

  @override
  bool get isAvailable => true;

  @override
  Future<String?> pick({String? initialDirectory}) async => chosen;
}
