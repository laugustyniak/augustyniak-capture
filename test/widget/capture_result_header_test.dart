import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:augustyniak_capture/features/recordings/domain/capture_category.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_router.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/domain/route_record.dart';
import 'package:augustyniak_capture/features/recordings/domain/suggested_route.dart';
import 'package:augustyniak_capture/features/recordings/presentation/capture_focus_view.dart';
import 'package:augustyniak_capture/features/recordings/presentation/capture_result_header.dart';
import 'package:augustyniak_capture/features/recordings/presentation/queue_tab.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/settings/domain/audio_config.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';

import '../support/harness.dart';

class _WritingRecorder implements AudioRecorder {
  String? _path;

  @override
  Future<bool> hasPermission({bool request = true}) async => true;

  @override
  Future<void> start(RecordConfig config, {required String path}) async {
    File(path).writeAsBytesSync(<int>[1, 2, 3], flush: true);
    _path = path;
  }

  @override
  Future<String?> stop() async => _path;

  @override
  dynamic noSuchMethod(Invocation invocation) async => null;
}

class _SlowTranscription implements TranscriptionService {
  final Completer<void> gate = Completer<void>();
  @override
  Future<String> transcribe(File audioFile) async {
    await gate.future;
    return 'hello world';
  }
}

class _FileRouter implements CaptureRouter {
  final List<String?> routed = <String?>[];

  /// When set, a delivery stays in flight until it completes.
  Completer<void>? hold;
  @override
  bool canRoute(String? projectId) => true;
  @override
  RouteKind? resolvedKind(RoutedCapture capture) => RouteKind.file;
  @override
  Future<RouteRecord> route(RoutedCapture capture) async {
    routed.add(capture.projectId);
    await hold?.future;
    return RouteRecord(
      at: DateTime.utc(2026, 11, 20),
      kind: RouteKind.file,
      target: 'inbox',
    );
  }
}

void main() {
  late Directory appDir;

  setUp(() => appDir = Directory.systemTemp.createTempSync('capture_header_'));
  tearDown(() => appDir.deleteSync(recursive: true));

  Future<RecordingsController> controllerFor(
    List<Recording> seed, {
    TranscriptionService? transcription,
    CaptureRouter? router,
  }) async {
    final RecordingsController controller = RecordingsController(
      repository: FakeRecordingsRepository(appDir, seed: seed),
      transcriptionService:
          transcription ?? const DisabledTranscriptionService(),
      recorder: _WritingRecorder(),
      player: FakePlayer(),
      audioConfig: const AudioConfig(sampleRate: 16000, bitRate: 64000),
      captureRouter: router ?? _FileRouter(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    return controller;
  }

  /// Polls real time for [condition]; a fixed sleep would encode a guess about
  /// how busy the machine is.
  Future<void> until(WidgetTester tester, bool Function() condition) async {
    await tester.runAsync(() async {
      for (int i = 0; i < 200 && !condition(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();
    expect(condition(), isTrue, reason: 'condition not reached in time');
  }

  Future<void> pumpHeader(
    WidgetTester tester,
    RecordingsController controller,
    Recording recording, {
    VoidCallback? onAppendRecording,
  }) async {
    await tester.pumpWidget(
      hostTab(
        () => CaptureResultHeader(
          controller: controller,
          recording: recording,
          onAppendRecording: onAppendRecording,
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> pumpQueue(
    WidgetTester tester,
    RecordingsController controller,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      hostTab(() => QueueTab(controller: controller), listenable: controller),
    );
    await tester.pump();
  }

  Recording suggested({bool processed = false}) => makeRecording(
    id: 'r1',
    title: 'Plan the launch',
    transcript: 'ship it',
    summary: 'ship it',
    category: CaptureCategory.task,
    projectId: 'p',
    isProcessedByUser: processed,
    sizeBytes: 2048,
    suggestedRoute: const SuggestedRoute(
      kind: SuggestedRouteKind.file,
      reason: 'looks like a task',
    ),
  );

  testWidgets('a fresh voice note shows SAVED and its size, then DONE', (
    WidgetTester tester,
  ) async {
    final _SlowTranscription slow = _SlowTranscription();
    final RecordingsController controller = await controllerFor(
      <Recording>[],
      transcription: slow,
    );
    await pumpQueue(tester, controller);

    await tester.runAsync(() async {
      await controller.startRecording();
      await controller.stopRecording();
      for (
        int i = 0;
        i < 200 &&
            controller.recordings.first.status != RecordingStatus.transcribing;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();
    expect(controller.recordings, isNotEmpty);

    expect(find.byType(CaptureResultHeader), findsOneWidget);
    expect(find.text('SAVED · 3 B'), findsOneWidget);
    expect(find.text(CaptureResultHeader.doneLabel), findsNothing);

    await tester.runAsync(() async => slow.gate.complete());
    await until(
      tester,
      () => controller.recordings.first.status == RecordingStatus.completed,
    );

    expect(find.text('SAVED · 3 B'), findsOneWidget);
    expect(find.text(CaptureResultHeader.doneLabel), findsOneWidget);
  });

  testWidgets('an auto suggested route is the primary action and routes', (
    WidgetTester tester,
  ) async {
    final _FileRouter router = _FileRouter();
    final RecordingsController controller = await controllerFor(<Recording>[
      suggested(),
    ], router: router);
    await pumpQueue(tester, controller);
    await tester.tap(find.text('Plan the launch').first);
    await tester.pump();

    expect(find.text(CaptureResultHeader.enrichedLabel), findsOneWidget);
    final Finder primary = find.byKey(CaptureResultHeader.routeButtonKey);
    expect(primary, findsOneWidget);
    expect(
      find.descendant(of: primary, matching: find.text('Send to inbox')),
      findsOneWidget,
    );

    await tester.tap(primary);
    await until(tester, () => controller.recordings.single.routes.isNotEmpty);

    expect(router.routed, hasLength(1));
    final Recording after = controller.recordings.single;
    expect(after.routes, hasLength(1));
    expect(after.isProcessedByUser, isTrue);
  });

  testWidgets('a second tap while the route is in flight delivers once', (
    WidgetTester tester,
  ) async {
    final _FileRouter router = _FileRouter()..hold = Completer<void>();
    final RecordingsController controller = await controllerFor(<Recording>[
      suggested(),
    ], router: router);
    await pumpQueue(tester, controller);
    await tester.tap(find.text('Plan the launch').first);
    await tester.pump();

    final Finder primary = find.byKey(CaptureResultHeader.routeButtonKey);
    await tester.tap(primary);
    await tester.pump();
    await tester.tap(primary, warnIfMissed: false);
    await tester.pump();
    expect(router.routed, hasLength(1));

    router.hold!.complete();
    await until(tester, () => controller.recordings.single.routes.isNotEmpty);
    expect(router.routed, hasLength(1));
  });

  testWidgets('no suggestion means no primary route button', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await controllerFor(<Recording>[
      makeRecording(
        id: 'r1',
        title: 'Plain note',
        transcript: 'x',
        category: CaptureCategory.task,
      ),
    ], router: _FileRouter());
    await pumpQueue(tester, controller);
    await tester.tap(find.text('Plain note').first);
    await tester.pump();

    expect(find.byType(CaptureResultHeader), findsOneWidget);
    expect(find.byKey(CaptureResultHeader.routeButtonKey), findsNothing);
    expect(find.byKey(CaptureResultHeader.copyButtonKey), findsOneWidget);
  });

  testWidgets('a reviewed capture shows no header', (
    WidgetTester tester,
  ) async {
    final Recording reviewed = suggested(processed: true);
    final RecordingsController controller = await controllerFor(<Recording>[
      reviewed,
    ], router: _FileRouter());
    await tester.pumpWidget(
      hostTab(
        () => CaptureDetailPanel(
          controller: controller,
          recording: reviewed,
          projectName: null,
          showMetaColumn: false,
          onEdit: () {},
          onToggleProcessed: () {},
          onConfirmSuggestedRoute: () async {},
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(CaptureDetailPanel), findsOneWidget);
    expect(find.byType(CaptureResultHeader), findsNothing);
  });

  testWidgets('+ Fragment opens the append menu when callbacks are present', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await controllerFor(<Recording>[]);
    int appended = 0;
    await pumpHeader(
      tester,
      controller,
      suggested(),
      onAppendRecording: () => appended++,
    );

    await tester.tap(find.text('+ Fragment'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'RECORDING'));
    await tester.pumpAndSettle();

    expect(appended, 1);
  });

  testWidgets('+ Fragment is absent without append callbacks', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await controllerFor(<Recording>[]);
    await pumpHeader(tester, controller, suggested());

    expect(find.text('+ Fragment'), findsNothing);
  });

  testWidgets('a failed capture shows FAILED', (WidgetTester tester) async {
    final RecordingsController controller = await controllerFor(<Recording>[]);
    await pumpHeader(
      tester,
      controller,
      makeRecording(id: 'f', status: RecordingStatus.failed, sizeBytes: 3),
    );

    expect(find.text(CaptureResultHeader.failedLabel), findsOneWidget);
    expect(find.text(CaptureResultHeader.doneLabel), findsNothing);
  });

  final String? out = Platform.environment['CAPTURE_HEADER_PNG'];
  testWidgets('renders the header to a PNG when asked', skip: out == null, (
    WidgetTester tester,
  ) async {
    // The test binding draws text as boxes; load the real faces so the
    // render shows words. Icons come from the SDK when FLUTTER_ROOT is set.
    await tester.runAsync(() async {
      Future<void> load(String family, List<String> paths) async {
        final FontLoader loader = FontLoader(family);
        for (final String path in paths) {
          if (!File(path).existsSync()) continue;
          final Uint8List bytes = File(path).readAsBytesSync();
          loader.addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
        }
        await loader.load();
      }

      const List<String> weights = <String>[
        'Regular',
        'Medium',
        'SemiBold',
        'Bold',
      ];
      await load('SpaceGrotesk', <String>[
        for (final String w in weights) 'assets/fonts/SpaceGrotesk-$w.ttf',
      ]);
      await load('JetBrainsMono', <String>[
        for (final String w in weights) 'assets/fonts/JetBrainsMono-$w.ttf',
      ]);
      final String? root = Platform.environment['FLUTTER_ROOT'];
      if (root != null) {
        await load('MaterialIcons', <String>[
          '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        ]);
      }
    });
    final RecordingsController controller = await controllerFor(<Recording>[
      suggested(),
    ], router: _FileRouter());
    await pumpQueue(tester, controller);
    await tester.tap(find.text('Plan the launch').first);
    await tester.pump();
    final RenderRepaintBoundary boundary = tester
        .renderObject<RenderRepaintBoundary>(
          find.byKey(CaptureResultHeader.boundaryKey),
        );
    await tester.runAsync(() async {
      final ui.Image image = await boundary.toImage(pixelRatio: 2);
      final ByteData? bytes = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      File(out!).writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  });
}
