import 'dart:async';
import 'dart:io';

import 'package:augustyniak_capture/features/settings/domain/app_settings.dart';
import 'package:augustyniak_capture/features/settings/domain/provider_profile.dart';
import 'package:augustyniak_capture/features/settings/presentation/local_models_section.dart';
import 'package:augustyniak_capture/features/settings/presentation/settings_controller.dart';
import 'package:augustyniak_capture/features/transcription/data/whisper_model_store.dart';
import 'package:augustyniak_capture/features/transcription/domain/local_transcription_engine.dart';
import 'package:augustyniak_capture/features/transcription/domain/whisper_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

/// Extends the real store and overrides only the IO, the convention
/// `_FakeSettingsRepository` already follows — so the section drives the real
/// class and the suite reaches no filesystem and no socket.
class _FakeStore extends WhisperModelStore {
  _FakeStore({this.present = const <String>{}, this.failListing = false});

  Set<String> present;
  final bool failListing;

  final List<String> downloaded = <String>[];
  final List<String> deleted = <String>[];

  /// Held so a test can watch a download in flight rather than only its result.
  Completer<void>? gate;
  void Function(ModelDownloadProgress progress)? lastProgress;

  @override
  Future<List<InstalledModel>> installed() async {
    if (failListing) throw const FileSystemException('unreadable');
    return <InstalledModel>[
      for (final String id in present)
        InstalledModel(
          id: id,
          path: '/models/$id.bin',
          bytes: 60 * 1024 * 1024,
          verified: false,
        ),
    ];
  }

  @override
  Future<InstalledModel> download(
    WhisperModel model, {
    void Function(ModelDownloadProgress progress)? onProgress,
    Future<void>? cancelledBy,
  }) async {
    downloaded.add(model.id);
    lastProgress = onProgress;
    onProgress?.call(
      const ModelDownloadProgress(received: 30, total: 100),
    );
    if (gate != null) {
      await Future.any(<Future<void>>[
        gate!.future,
        if (cancelledBy != null)
          cancelledBy.then((_) => throw const ModelDownloadCancelled()),
      ]);
    }
    present = <String>{...present, model.id};
    return InstalledModel(
      id: model.id,
      path: '/models/${model.id}.bin',
      bytes: 60 * 1024 * 1024,
      verified: false,
    );
  }

  @override
  Future<bool> delete(String id) async {
    deleted.add(id);
    present = <String>{...present}..remove(id);
    return true;
  }
}

class _ReadyEngine implements LocalTranscriptionEngine {
  const _ReadyEngine();

  @override
  bool get isAvailable => true;

  @override
  String? get unavailableReason => null;

  @override
  Future<String> transcribe({
    required File audio,
    required String modelPath,
    String? language,
  }) async => 'text';
}

void main() {
  final WhisperModel first = WhisperModelCatalog.all.first;

  Future<SettingsController> controllerWith({
    bool engineReady = false,
    AppSettings? stored,
  }) async {
    final SettingsController controller = buildSettingsController(
      stored: stored,
      localEngine: engineReady
          ? const _ReadyEngine()
          : const UnavailableLocalEngine('no native engine in this build'),
    );
    await controller.initialize();
    return controller;
  }

  Future<void> pumpSection(
    WidgetTester tester,
    SettingsController controller,
    WhisperModelStore store,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: SingleChildScrollView(
            child: ListenableBuilder(
              listenable: controller,
              builder: (BuildContext context, Widget? child) =>
                  LocalModelsSection(controller: controller, store: store),
            ),
          ),
        ),
      ),
    );
    // The scan is kicked from initState and touches the store.
    await tester.pump();
    await tester.pump();
  }

  testWidgets('an install with nothing downloaded lists the catalog', (
    WidgetTester tester,
  ) async {
    final SettingsController controller = await controllerWith();
    await pumpSection(tester, controller, _FakeStore());

    for (final WhisperModel model in WhisperModelCatalog.all) {
      expect(find.text(model.label), findsOneWidget);
    }
    expect(find.textContaining('Not installed'), findsNWidgets(4));
    expect(find.text('DOWNLOAD'), findsNWidgets(4));
    // Nothing claims to be active, because nothing is.
    expect(find.text('ACTIVE'), findsNothing);
  });

  testWidgets('a build with no engine says so once, not per capture', (
    WidgetTester tester,
  ) async {
    final SettingsController controller = await controllerWith();
    await pumpSection(tester, controller, _FakeStore());

    expect(
      find.textContaining('no native engine in this build'),
      findsOneWidget,
    );
  });

  testWidgets('an installed model can be used, and says which is active', (
    WidgetTester tester,
  ) async {
    final _FakeStore store = _FakeStore(present: <String>{first.id});
    final SettingsController controller = await controllerWith(
      engineReady: true,
    );
    await pumpSection(tester, controller, store);

    expect(find.text('INSTALLED'), findsOneWidget);
    // The honest wording while no checksum is pinned.
    expect(
      find.textContaining('no published checksum'),
      findsOneWidget,
    );

    await tester.tap(find.text('USE'));
    await tester.pump();
    await tester.pump();

    expect(find.text('ACTIVE'), findsOneWidget);
    expect(controller.activeLocalModelId, first.id);
    // One profile per model, not one per tap.
    expect(
      controller.profiles.where(
        (ProviderProfile p) => p.kind == ProfileKind.localWhisper,
      ),
      hasLength(1),
    );
  });

  testWidgets('using the same model twice does not stack profiles', (
    WidgetTester tester,
  ) async {
    final _FakeStore store = _FakeStore(present: <String>{first.id});
    final SettingsController controller = await controllerWith(
      engineReady: true,
    );
    await pumpSection(tester, controller, store);

    await tester.tap(find.text('USE'));
    await tester.pump();
    await tester.pump();
    await controller.setActiveProfile(null);
    await tester.pump();
    await tester.tap(find.text('USE'));
    await tester.pump();
    await tester.pump();

    expect(
      controller.profiles.where(
        (ProviderProfile p) => p.kind == ProfileKind.localWhisper,
      ),
      hasLength(1),
    );
  });

  testWidgets('without an engine a model can be managed but not used', (
    WidgetTester tester,
  ) async {
    final _FakeStore store = _FakeStore(present: <String>{first.id});
    final SettingsController controller = await controllerWith();
    await pumpSection(tester, controller, store);

    // Downloading and deleting stay available: what the missing native side
    // stops is *running* a model.
    expect(find.text('DELETE'), findsOneWidget);
    await tester.tap(find.text('USE'));
    await tester.pump();
    await tester.pump();

    expect(controller.activeLocalModelId, isNull);
  });

  testWidgets('a download reports progress and can be cancelled', (
    WidgetTester tester,
  ) async {
    final _FakeStore store = _FakeStore()..gate = Completer<void>();
    final SettingsController controller = await controllerWith();
    await pumpSection(tester, controller, store);

    await tester.tap(find.text('DOWNLOAD').first);
    await tester.pump();

    expect(store.downloaded, <String>[first.id]);
    expect(find.textContaining('Downloading · 30%'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    await tester.tap(find.text('CANCEL'));
    await tester.pump();
    await tester.pump();

    // A cancel is a decision, not a failure: nothing red is shown for it.
    expect(find.textContaining('Downloading'), findsNothing);
    expect(find.textContaining('cancelled'), findsNothing);
  });

  testWidgets('a finished download flips the row to installed', (
    WidgetTester tester,
  ) async {
    final _FakeStore store = _FakeStore();
    final SettingsController controller = await controllerWith();
    await pumpSection(tester, controller, store);

    await tester.tap(find.text('DOWNLOAD').first);
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('INSTALLED'), findsOneWidget);
    expect(find.text('DOWNLOAD'), findsNWidgets(3));
  });

  testWidgets('an unreadable models directory is reported, not assumed empty', (
    WidgetTester tester,
  ) async {
    // "Nothing is installed" is a positive claim about the user's disk, and it
    // must not be made when the disk merely could not be read.
    final SettingsController controller = await controllerWith();
    await pumpSection(tester, controller, _FakeStore(failListing: true));

    expect(
      find.textContaining('Could not read the installed models'),
      findsOneWidget,
    );
  });
}
