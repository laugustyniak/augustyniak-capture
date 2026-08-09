import 'dart:io';

import 'package:augustyniak_capture/features/gamification/presentation/gamification_controller.dart';
import 'package:augustyniak_capture/features/momentum/domain/closure_event.dart';
import 'package:augustyniak_capture/features/projects/domain/project.dart';
import 'package:augustyniak_capture/features/recordings/data/project_inbox_router.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/domain/route_record.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

/// Records what was appended, so a test can assert the count and the kind
/// without a filesystem. Same shape as `_MemoryLogArchive` in the harness.
class _RecordingClosureLog implements ClosureLog {
  final List<ClosureEvent> appended = <ClosureEvent>[];
  List<ClosureEvent> preloaded = const <ClosureEvent>[];

  @override
  Future<List<ClosureEvent>> load() async => preloaded;

  @override
  Future<void> append(ClosureEvent event) async => appended.add(event);
}

/// Fails every append, to prove a broken log never fails a close.
class _FailingClosureLog implements ClosureLog {
  const _FailingClosureLog();

  @override
  Future<List<ClosureEvent>> load() async => const <ClosureEvent>[];

  @override
  Future<void> append(ClosureEvent event) async =>
      throw const FileSystemException('disk full');
}

/// Refuses to load, so the dedup read has to survive it.
class _UnreadableClosureLog implements ClosureLog {
  const _UnreadableClosureLog();

  @override
  Future<List<ClosureEvent>> load() async =>
      throw const FileSystemException('permission denied');

  @override
  Future<void> append(ClosureEvent event) async {}
}

void main() {
  late Directory appDir;
  late Directory repo;

  setUp(() {
    appDir = Directory.systemTemp.createTempSync('augustyniak-momentum-app-');
    repo = Directory.systemTemp.createTempSync('augustyniak-momentum-repo-');
  });

  tearDown(() {
    appDir.deleteSync(recursive: true);
    if (repo.existsSync()) repo.deleteSync(recursive: true);
  });

  ProjectInboxRouter routerFor(Directory target) {
    final Project project = Project(
      id: 'p1',
      name: 'Acme',
      repoPath: target.path,
    );
    return ProjectInboxRouter(
      projectById: (String id) => id == 'p1' ? project : null,
    );
  }

  test('closing a capture by hand records one review closure', () async {
    final _RecordingClosureLog log = _RecordingClosureLog();
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[makeRecording(id: 'r1', type: CaptureType.text)],
      closureLog: log,
    );

    await controller.toggleProcessed('r1');

    expect(log.appended.length, 1);
    expect(log.appended.single.recordingId, 'r1');
    expect(log.appended.single.kind, ClosureKind.review);
    expect(log.appended.single.type, CaptureType.text);
  });

  test('un-closing and re-closing records nothing the second time', () async {
    // A capture closes once, ever — otherwise the count could be farmed by
    // toggling one row rather than by doing any work, which is the whole
    // reason closures were chosen as the metric over captures.
    final _RecordingClosureLog log = _RecordingClosureLog();
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[makeRecording(id: 'r1')],
      closureLog: log,
    );

    await controller.toggleProcessed('r1'); // closed
    await controller.toggleProcessed('r1'); // re-opened
    await controller.toggleProcessed('r1'); // closed again

    expect(log.appended.length, 1);
  });

  test('routing records exactly one closure, of kind route', () async {
    // `route()` sets isProcessedByUser itself, so an implementation that
    // appended at each call site rather than in the `_update` funnel would
    // record two events for one delivery.
    final _RecordingClosureLog log = _RecordingClosureLog();
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[makeRecording(id: 'r1', projectId: 'p1')],
      captureRouter: routerFor(repo),
      closureLog: log,
    );

    await controller.route('r1');

    expect(log.appended.length, 1);
    expect(log.appended.single.kind, ClosureKind.route);
  });

  test('routing twice still records one closure', () async {
    // `Recording.routes` deliberately appends on a second delivery — both
    // deliveries happened. The closure count answers a different question:
    // how many captures left the desk, and one capture leaves it once.
    final _RecordingClosureLog log = _RecordingClosureLog();
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[makeRecording(id: 'r1', projectId: 'p1')],
      captureRouter: routerFor(repo),
      closureLog: log,
    );

    await controller.route('r1');
    await controller.route('r1');

    expect(controller.recordings.single.routes.length, 2);
    expect(log.appended.length, 1);
  });

  test('a closure carries the capture project, denormalised', () async {
    // Both the id and the name, like `FocusSession`: the id groups, the name is
    // what a panel can still show once the project is renamed or deleted.
    final _RecordingClosureLog log = _RecordingClosureLog();
    final Project project = Project(
      id: 'p1',
      name: 'Acme',
      repoPath: repo.path,
    );
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[makeRecording(id: 'r1', projectId: 'p1')],
      closureLog: log,
      projectById: (String id) => id == 'p1' ? project : null,
    );

    await controller.toggleProcessed('r1');

    expect(log.appended.single.projectId, 'p1');
    expect(log.appended.single.projectName, 'Acme');
  });

  test('a capture with no project still records a closure', () async {
    final _RecordingClosureLog log = _RecordingClosureLog();
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[makeRecording(id: 'r1')],
      closureLog: log,
    );

    await controller.toggleProcessed('r1');

    expect(log.appended.single.projectId, isNull);
    expect(log.appended.single.projectName, isNull);
  });

  test('a failing closure log never fails the close', () async {
    // Best-effort under the ClipboardSink contract: the capture did leave the
    // desk, and a store that could not record it must not undo that.
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[makeRecording(id: 'r1')],
      closureLog: const _FailingClosureLog(),
    );

    await controller.toggleProcessed('r1');

    expect(controller.recordings.single.isProcessedByUser, isTrue);
    expect(controller.error, isNull);
  });

  test('a capture closed in an earlier session is not counted again', () async {
    final _RecordingClosureLog log = _RecordingClosureLog()
      ..preloaded = <ClosureEvent>[
        ClosureEvent(
          recordingId: 'r1',
          at: DateTime(2026, 8, 1),
          kind: ClosureKind.review,
          type: CaptureType.text,
        ),
      ];
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[makeRecording(id: 'r1', isProcessedByUser: true)],
      closureLog: log,
    );
    await controller.loadClosures();

    await controller.toggleProcessed('r1'); // re-opened
    await controller.toggleProcessed('r1'); // closed again

    expect(log.appended, isEmpty);
  });

  test('an unreadable log costs deduplication, never the close', () async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[makeRecording(id: 'r1')],
      closureLog: const _UnreadableClosureLog(),
    );

    await controller.loadClosures();
    await controller.toggleProcessed('r1');

    expect(controller.recordings.single.isProcessedByUser, isTrue);
    expect(controller.error, isNull);
  });

  test('the milestone tally counts a capture once, not once per tick', () async {
    // The defect this replaced: `onCaptureDone` was called from each closing
    // path and incremented by one every time, so un-ticking and re-ticking a
    // single row raised the lifetime total — badges could be farmed by
    // clicking rather than by finishing anything. Routing it through the
    // `_update` funnel is what makes the tally mean work done.
    //
    // `GamificationRepository` swallows the missing plugin and answers with
    // defaults, so the real controller runs entirely in memory here.
    final GamificationController gamification = GamificationController();
    await gamification.initialize();
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[makeRecording(id: 'r1')],
      closureLog: _RecordingClosureLog(),
      gamificationController: gamification,
    );

    await controller.toggleProcessed('r1'); // closed
    await controller.toggleProcessed('r1'); // re-opened
    await controller.toggleProcessed('r1'); // closed again

    expect(gamification.stats.totalCapturesDone, 1);
  });

  group('backfill', () {
    // Without this, an install with a hundred closed captures opens the panel
    // on "Nothing closed yet" and a target of 1 — a history starting at zero
    // for someone whose work is all behind them. The same reasoning makes
    // `mirrorAll()` non-optional for the note vault.

    test('records one closure per already-closed capture', () async {
      final _RecordingClosureLog log = _RecordingClosureLog();
      final RecordingsController controller = await buildRecordingsController(
        appDir,
        seed: <Recording>[
          makeRecording(
            id: 'r1',
            isProcessedByUser: true,
            processedAt: DateTime(2026, 8, 1, 10),
          ),
          makeRecording(
            id: 'r2',
            isProcessedByUser: true,
            processedAt: DateTime(2026, 8, 2, 10),
          ),
          makeRecording(id: 'r3'), // still open
        ],
        closureLog: log,
      );

      final ClosureBackfill summary = await controller.backfillClosures();

      expect(summary.recorded, 2);
      expect(log.appended.length, 2);
      expect(
        log.appended.map((ClosureEvent e) => e.recordingId),
        <String>['r1', 'r2'],
      );
    });

    test('dates each closure by when it was actually closed', () async {
      // The whole point of the file is a truthful timeline; stamping the
      // backfill with "now" would put a hundred closures on one day and make
      // the pace meaningless for a fortnight.
      final _RecordingClosureLog log = _RecordingClosureLog();
      final RecordingsController controller = await buildRecordingsController(
        appDir,
        seed: <Recording>[
          makeRecording(
            id: 'r1',
            isProcessedByUser: true,
            processedAt: DateTime(2026, 8, 1, 10),
          ),
        ],
        closureLog: log,
      );

      await controller.backfillClosures();

      expect(log.appended.single.at, DateTime(2026, 8, 1, 10));
    });

    test('skips a closed capture with no processedAt, and counts it', () async {
      // A row written before the field existed. Inventing a date would put a
      // fact in an append-only file that never happened — worse than admitting
      // the row cannot be placed.
      final _RecordingClosureLog log = _RecordingClosureLog();
      final RecordingsController controller = await buildRecordingsController(
        appDir,
        seed: <Recording>[makeRecording(id: 'r1', isProcessedByUser: true)],
        closureLog: log,
      );

      final ClosureBackfill summary = await controller.backfillClosures();

      expect(log.appended, isEmpty);
      expect(summary.recorded, 0);
      expect(summary.undatable, 1);
    });

    test('infers the kind from where the capture actually went', () async {
      final _RecordingClosureLog log = _RecordingClosureLog();
      final RecordingsController controller = await buildRecordingsController(
        appDir,
        seed: <Recording>[
          makeRecording(
            id: 'inbox',
            isProcessedByUser: true,
            processedAt: DateTime(2026, 8, 1, 10),
            routes: <RouteRecord>[
              RouteRecord(
                at: DateTime(2026, 8, 1, 10),
                kind: RouteKind.file,
                target: 'inbox.md',
              ),
            ],
          ),
          makeRecording(
            id: 'agent',
            isProcessedByUser: true,
            processedAt: DateTime(2026, 8, 1, 11),
            routes: <RouteRecord>[
              RouteRecord(
                at: DateTime(2026, 8, 1, 11),
                kind: RouteKind.agent,
                target: 'claude',
              ),
            ],
          ),
          makeRecording(
            id: 'ticked',
            isProcessedByUser: true,
            processedAt: DateTime(2026, 8, 1, 12),
          ),
        ],
        closureLog: log,
      );

      await controller.backfillClosures();

      expect(
        log.appended.map((ClosureEvent e) => e.kind),
        <ClosureKind>[
          ClosureKind.route,
          ClosureKind.handoff,
          ClosureKind.review,
        ],
      );
    });

    test('running it twice records nothing the second time', () async {
      // `_closedIds` already guarantees this, but the sweep is the one caller
      // a user can press repeatedly, so it gets its own assertion.
      final _RecordingClosureLog log = _RecordingClosureLog();
      final RecordingsController controller = await buildRecordingsController(
        appDir,
        seed: <Recording>[
          makeRecording(
            id: 'r1',
            isProcessedByUser: true,
            processedAt: DateTime(2026, 8, 1, 10),
          ),
        ],
        closureLog: log,
      );

      await controller.backfillClosures();
      final ClosureBackfill second = await controller.backfillClosures();

      expect(log.appended.length, 1);
      expect(second.recorded, 0);
      expect(second.alreadyKnown, 1);
    });

    test('a failing log costs the row, never the sweep', () async {
      final RecordingsController controller = await buildRecordingsController(
        appDir,
        seed: <Recording>[
          makeRecording(
            id: 'r1',
            isProcessedByUser: true,
            processedAt: DateTime(2026, 8, 1, 10),
          ),
          makeRecording(
            id: 'r2',
            isProcessedByUser: true,
            processedAt: DateTime(2026, 8, 2, 10),
          ),
        ],
        closureLog: const _FailingClosureLog(),
      );

      final ClosureBackfill summary = await controller.backfillClosures();

      expect(summary.failed, 2);
      expect(controller.error, isNull);
    });
  });

  test('re-opening a capture leaves the recorded closure alone', () async {
    // The log is append-only. Nothing here may delete a row: the capture did
    // leave the desk that day, and it coming back is a new fact, not a reason
    // to rewrite an old one.
    final _RecordingClosureLog log = _RecordingClosureLog();
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[makeRecording(id: 'r1')],
      closureLog: log,
    );

    await controller.toggleProcessed('r1');
    await controller.toggleProcessed('r1');

    expect(log.appended.length, 1);
    expect(controller.recordings.single.isProcessedByUser, isFalse);
  });
}
