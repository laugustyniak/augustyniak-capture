import 'dart:io';

import 'package:augustyniak_capture/features/projects/domain/project.dart';
import 'package:augustyniak_capture/features/recordings/data/project_inbox_router.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_category.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_router.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/domain/route_record.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

/// Fails every delivery, to prove that a capture whose routing threw is left
/// exactly as it was rather than closed on a promise nothing kept.
class _FailingRouter implements CaptureRouter {
  const _FailingRouter();

  @override
  bool canRoute(String? projectId) => true;

  @override
  Future<RouteRecord> route(RoutedCapture capture) async {
    throw const FileSystemException('repo is gone');
  }
}

void main() {
  late Directory appDir;
  late Directory repo;

  setUp(() {
    appDir = Directory.systemTemp.createTempSync('augustyniak-routing-app-');
    repo = Directory.systemTemp.createTempSync('augustyniak-routing-repo-');
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

  test('routing writes the capture into the project inbox and closes it', () async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(
          id: 'r1',
          projectId: 'p1',
          title: 'Ship the light theme',
          transcript: 'implement every part of the light theme',
          summary: 'Light theme work.',
          category: CaptureCategory.agentTask,
          tags: const <String>['ui'],
        ),
      ],
      captureRouter: routerFor(repo),
    );

    await controller.route('r1');

    final File inbox = File('${repo.path}${Platform.pathSeparator}inbox.md');
    final String written = await inbox.readAsString();
    expect(written, contains('## Ship the light theme'));
    expect(written, contains('agentTask'));
    expect(written, contains('#ui'));
    expect(written, contains('> Light theme work.'));
    expect(written, contains('implement every part of the light theme'));

    final Recording routed = controller.recordings.single;
    expect(routed.routes, hasLength(1));
    expect(routed.routes.single.kind, RouteKind.file);
    expect(routed.routes.single.target, 'inbox.md · Acme');
    // Closing the item is the consequence of routing it, not a second chore.
    // This is what lets the queue drain as a side effect of the work.
    expect(routed.isProcessedByUser, isTrue);
    expect(routed.processedAt, routed.routes.single.at);
  });

  test('a second delivery appends rather than replacing the first', () async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(id: 'r1', projectId: 'p1', title: 'Twice'),
      ],
      captureRouter: routerFor(repo),
    );

    await controller.route('r1');
    await controller.route('r1');

    // Both deliveries really happened and the second does not undo the first —
    // the file has two entries, so the history must have two rows.
    expect(controller.recordings.single.routes, hasLength(2));
    final File inbox = File('${repo.path}${Platform.pathSeparator}inbox.md');
    expect('## Twice'.allMatches(await inbox.readAsString()), hasLength(2));
  });

  test('the inbox is appended to, never rewritten', () async {
    final File inbox = File('${repo.path}${Platform.pathSeparator}inbox.md');
    await inbox.writeAsString('# Inbox\n\nSomething the user wrote.\n');

    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(id: 'r1', projectId: 'p1', title: 'Appended'),
      ],
      captureRouter: routerFor(repo),
    );
    await controller.route('r1');

    // The destination file is not ours: the user edits it. Rewriting it from
    // memory is the exact shape that once destroyed the recordings index.
    final String written = await inbox.readAsString();
    expect(written, startsWith('# Inbox'));
    expect(written, contains('Something the user wrote.'));
    expect(written, contains('## Appended'));
  });

  test('a failed delivery leaves the capture open and unrouted', () async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[makeRecording(id: 'r1', projectId: 'p1')],
      captureRouter: const _FailingRouter(),
    );

    await controller.route('r1');

    // A capture ticked off as routed but never delivered is strictly worse than
    // one never routed: the first is invisible, the second is still in the
    // inbox where the user will see it again.
    final Recording item = controller.recordings.single;
    expect(item.routes, isEmpty);
    expect(item.isProcessedByUser, isFalse);
    expect(controller.error, isNotNull);
  });

  test('a capture with no project has nowhere to go', () async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[makeRecording(id: 'r1')],
      captureRouter: routerFor(repo),
    );

    expect(controller.canRoute(controller.recordings.single), isFalse);
  });

  test('a moved repository is named, not swallowed', () async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[makeRecording(id: 'r1', projectId: 'p1')],
      captureRouter: routerFor(repo),
    );
    repo.deleteSync(recursive: true);

    await controller.route('r1');

    // A moved checkout and an empty inbox are indistinguishable from the queue,
    // and only one of them is the user's problem to fix.
    expect(controller.error, contains('Project repository not found'));
    expect(controller.recordings.single.isProcessedByUser, isFalse);
  });
}
