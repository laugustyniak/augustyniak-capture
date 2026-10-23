import 'dart:io';

import 'package:augustyniak_capture/features/projects/data/native_agent_jobs.dart';
import 'package:augustyniak_capture/features/projects/domain/native_agent_types.dart';
import 'package:augustyniak_capture/features/settings/domain/queue_density.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording_revision.dart';
import 'package:augustyniak_capture/features/recordings/domain/route_record.dart';
import 'package:augustyniak_capture/features/recordings/presentation/agent_runs.dart';
import 'package:augustyniak_capture/features/recordings/presentation/queue_list_row.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recording_card.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recording_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

const NativeAgentJobHandle _handle = NativeAgentJobHandle(
  id: 'job-1',
  backend: NativeAgentBackend.claude,
);

Recording _withJob() => makeRecording(
  id: 'rec-1',
  routes: <RouteRecord>[
    RouteRecord(
      at: DateTime(2026),
      kind: RouteKind.agent,
      target: 'Claude Code',
      agentJob: _handle,
    ),
  ],
);

NativeAgentJob _job(
  NativeAgentJobStatus status, {
  String? result,
  String? conversationId = 'conv',
  DateTime? createdAt,
  DateTime? finishedAt,
}) => NativeAgentJob(
  handle: _handle,
  status: status,
  createdAt: createdAt ?? DateTime.now().subtract(const Duration(minutes: 2)),
  finishedAt: finishedAt,
  workspacePath: '/work/project',
  logs: 'log output',
  result: result,
  conversationId: conversationId,
);

class _FakeJobs extends NativeAgentJobs {
  _FakeJobs(this.job)
    : super(
        jobsRoot: () async => Directory.systemTemp,
        watchInterval: const Duration(milliseconds: 100),
      );

  NativeAgentJob? job;
  bool failReads = false;
  int reads = 0;
  final List<String> stopped = <String>[];
  final List<String> followedUp = <String>[];

  // The pill, card and section watch through `peek`; `read` has side effects.
  @override
  Future<NativeAgentJob> peek(String id) async {
    reads++;
    if (failReads || job == null) throw const FormatException('gone');
    return job!;
  }

  @override
  Future<NativeAgentJob> read(String id) => peek(id);

  @override
  Future<NativeAgentJobHandle> followUp(String id, String prompt) async {
    followedUp.add('$id:$prompt');
    return const NativeAgentJobHandle(
      id: 'child',
      backend: NativeAgentBackend.claude,
    );
  }

  @override
  Future<List<NativeAgentJob>> list() async => <NativeAgentJob>[?job];

  @override
  Future<void> stop(String id) async => stopped.add(id);
}

void main() {
  Future<void> mountSection(
    WidgetTester tester,
    Recording recording,
    NativeAgentJobs? jobs,
  ) async {
    await tester.pumpWidget(
      hostTab(
        () => SingleChildScrollView(
          child: AgentRunsSection(recording: recording, jobs: jobs),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('hidden when the capture has no local job', (tester) async {
    await mountSection(tester, makeRecording(id: 'plain'), _FakeJobs(null));
    expect(find.text('AGENT RUNS'), findsNothing);
  });

  testWidgets('hidden when no job store is wired', (tester) async {
    await mountSection(tester, _withJob(), null);
    expect(find.text('AGENT RUNS'), findsNothing);
  });

  testWidgets('running job shows pill, agent, duration and STOP', (
    tester,
  ) async {
    final _FakeJobs jobs = _FakeJobs(_job(NativeAgentJobStatus.running));
    await mountSection(tester, _withJob(), jobs);

    expect(find.text('AGENT RUNS'), findsOneWidget);
    expect(find.text('RUNNING'), findsOneWidget);
    expect(find.text('Claude Code'), findsOneWidget);
    expect(find.textContaining(RegExp(r'^\d\d:\d\d$')), findsOneWidget);
    expect(find.text('STOP'), findsOneWidget);
    expect(find.text('FOLLOW UP'), findsNothing);

    await tester.tap(find.text('STOP'));
    await tester.pump();
    expect(jobs.stopped, <String>['job-1']);
  });

  testWidgets('polls while running and stops once terminal', (tester) async {
    final _FakeJobs jobs = _FakeJobs(_job(NativeAgentJobStatus.running));
    await mountSection(tester, _withJob(), jobs);
    final int afterMount = jobs.reads;

    jobs.job = _job(NativeAgentJobStatus.completed, result: 'all done');
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump();
    expect(find.text('DONE'), findsOneWidget);
    expect(find.text('all done'), findsOneWidget);
    expect(jobs.reads, greaterThan(afterMount));

    final int terminalReads = jobs.reads;
    await tester.pump(const Duration(seconds: 1));
    expect(jobs.reads, terminalReads);
  });

  testWidgets('finished job: expandable preview, PR chip, FOLLOW UP', (
    tester,
  ) async {
    final String result =
        'line1\nline2\nline3\nline4\nline5\n'
        'Opened https://github.com/acme/app/pull/42 for review';
    final _FakeJobs jobs = _FakeJobs(
      _job(
        NativeAgentJobStatus.completed,
        result: result,
        createdAt: DateTime(2026, 1, 1, 10),
        finishedAt: DateTime(2026, 1, 1, 10, 2, 5),
      ),
    );
    await mountSection(tester, _withJob(), jobs);

    expect(find.text('PR acme/app#42'), findsOneWidget);
    expect(find.text('02:05'), findsOneWidget);
    expect(find.text('FOLLOW UP'), findsOneWidget);
    expect(find.text('STOP'), findsNothing);
    final Text preview = tester.widget<Text>(find.text(result));
    expect(preview.maxLines, 3);

    await tester.tap(find.text('SHOW MORE'));
    await tester.pump();
    expect(tester.widget<Text>(find.text(result)).maxLines, isNull);
  });

  testWidgets('VIEW LOG opens the jobs sheet on that job', (tester) async {
    final _FakeJobs jobs = _FakeJobs(_job(NativeAgentJobStatus.failed));
    await mountSection(tester, _withJob(), jobs);

    expect(find.text('FAILED'), findsOneWidget);
    await tester.tap(find.text('VIEW LOG'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Agent jobs'), findsOneWidget);
    expect(find.text('log output'), findsOneWidget);
  });

  testWidgets('an unreadable job never throws', (tester) async {
    final _FakeJobs jobs = _FakeJobs(null)..failReads = true;
    await mountSection(tester, _withJob(), jobs);

    expect(find.text('UNAVAILABLE'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a transient failure is retried and the pill recovers', (
    tester,
  ) async {
    final _FakeJobs jobs = _FakeJobs(_job(NativeAgentJobStatus.running));
    await mountSection(tester, _withJob(), jobs);
    jobs.failReads = true;
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump();
    expect(find.text('RUNNING'), findsOneWidget);

    jobs.failReads = false;
    jobs.job = _job(NativeAgentJobStatus.completed, result: 'back');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.text('DONE'), findsOneWidget);
  });

  testWidgets('a persistent failure gives up after bounded retries', (
    tester,
  ) async {
    final _FakeJobs jobs = _FakeJobs(_job(NativeAgentJobStatus.running));
    await mountSection(tester, _withJob(), jobs);
    jobs.failReads = true;
    await tester.pump(const Duration(milliseconds: 150));
    final int afterFirstFailure = jobs.reads;

    await tester.pump(const Duration(seconds: 10));
    final int settled = jobs.reads;
    expect(settled - afterFirstFailure, lessThanOrEqualTo(5));
    await tester.pump(const Duration(seconds: 10));
    expect(jobs.reads, settled);
    expect(find.text('RUNNING'), findsOneWidget);
  });

  testWidgets('a new watcher resumes a poller that gave up', (tester) async {
    final _FakeJobs jobs = _FakeJobs(_job(NativeAgentJobStatus.running));
    await mountSection(tester, _withJob(), jobs);
    jobs.failReads = true;
    await tester.pump(const Duration(seconds: 20));
    final int settled = jobs.reads;

    jobs.failReads = false;
    jobs.job = _job(NativeAgentJobStatus.completed, result: 'x');
    await tester.pumpWidget(
      hostTab(() => AgentRunPill(jobs: jobs, handle: _handle)),
    );
    await tester.pump();
    await tester.pump();
    expect(jobs.reads, greaterThan(settled));
    expect(find.text('AGENT · DONE'), findsOneWidget);
  });

  testWidgets('unmounting stops the polling', (tester) async {
    final _FakeJobs jobs = _FakeJobs(_job(NativeAgentJobStatus.running));
    await mountSection(tester, _withJob(), jobs);
    await tester.pump(const Duration(milliseconds: 150));
    expect(jobs.reads, greaterThan(1));

    await tester.pumpWidget(const SizedBox.shrink());
    final int afterUnmount = jobs.reads;
    await tester.pump(const Duration(seconds: 1));
    expect(jobs.reads, afterUnmount);
  });

  testWidgets('pill, card and section on one job share one poller', (
    tester,
  ) async {
    final _FakeJobs jobs = _FakeJobs(_job(NativeAgentJobStatus.running));
    await tester.pumpWidget(
      hostTab(
        () => Column(
          children: <Widget>[
            AgentRunPill(jobs: jobs, handle: _handle),
            AgentRunPill(jobs: jobs, handle: _handle),
            AgentRunsSection(recording: _withJob(), jobs: jobs),
          ],
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(jobs.reads, 1);

    await tester.pump(const Duration(milliseconds: 110));
    await tester.pump();
    expect(jobs.reads, 2);
  });

  testWidgets('lost reads as FAILED and offers no follow up', (tester) async {
    final _FakeJobs jobs = _FakeJobs(_job(NativeAgentJobStatus.lost));
    await mountSection(tester, _withJob(), jobs);

    expect(find.text('FAILED'), findsOneWidget);
    expect(find.text('FOLLOW UP'), findsNothing);
    expect(find.text('STOP'), findsNothing);
  });

  testWidgets('FOLLOW UP sends the prompt and opens the new job', (
    tester,
  ) async {
    final _FakeJobs jobs = _FakeJobs(
      _job(NativeAgentJobStatus.completed, result: 'done'),
    );
    await mountSection(tester, _withJob(), jobs);

    await tester.tap(find.text('FOLLOW UP'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(
      find.byKey(const ValueKey<String>('agent-job-follow-up-input')),
      'next step',
    );
    await tester.tap(find.text('SEND'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(jobs.followedUp, <String>['job-1:next step']);
    expect(find.text('Agent jobs'), findsOneWidget);
    // The card's buttons are usable again behind the sheet.
    expect(
      tester
          .widget<TextButton>(
            find.ancestor(
              of: find.text('FOLLOW UP'),
              matching: find.byWidgetPredicate((w) => w is TextButton),
            ),
          )
          .onPressed,
      isNotNull,
    );
  });

  test('PR url parsing accepts only github pull links, the last wins', () {
    expect(agentResultPrUrl(null), isNull);
    expect(agentResultPrUrl('see https://gitlab.com/a/b/pull/3'), isNull);
    expect(agentResultPrUrl('see http://github.com/a/b/pull/3'), isNull);
    expect(agentResultPrUrl('see https://github.com/a/b/issues/3'), isNull);
    expect(
      agentResultPrUrl(
        'old https://github.com/a/b/pull/1 new https://github.com/a/b/pull/2',
      ),
      Uri.parse('https://github.com/a/b/pull/2'),
    );
  });

  testWidgets('editor renders the section for a capture with a job', (
    tester,
  ) async {
    final _FakeJobs jobs = _FakeJobs(_job(NativeAgentJobStatus.running));
    await tester.pumpWidget(
      hostTab(
        () => SingleChildScrollView(
          child: RecordingEditor(
            recording: _withJob(),
            revisions: const <RecordingRevision>[],
            tagSuggestions: const <String>[],
            onTitleChanged: (_) {},
            onTextChanged: (_) {},
            onCategoryChanged: (_) {},
            onTagsChanged: (_) {},
            onDone: () {},
            agentJobs: jobs,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('AGENT RUNS'), findsOneWidget);
    expect(find.text('RUNNING'), findsOneWidget);
  });

  testWidgets('queue card carries an AGENT pill', (tester) async {
    final _FakeJobs jobs = _FakeJobs(_job(NativeAgentJobStatus.running));
    await tester.pumpWidget(
      hostTab(
        () => RecordingCard(
          recording: _withJob(),
          isPlaying: false,
          onTogglePlay: () {},
          onOpen: () {},
          onRetry: () {},
          onEnrich: () {},
          onEdit: () {},
          onToggleProcessed: () {},
          onRoute: () {},
          onHandoff: () {},
          agentJobs: jobs,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('AGENT · RUNNING'), findsOneWidget);
  });

  testWidgets('queue list row carries an AGENT pill', (tester) async {
    final _FakeJobs jobs = _FakeJobs(
      _job(NativeAgentJobStatus.completed, result: 'x'),
    );
    await tester.pumpWidget(
      hostTab(
        () => QueueListRow(
          recording: _withJob(),
          selected: false,
          isEnriching: false,
          density: QueueDensity.comfortable,
          onTap: () {},
          agentJobs: jobs,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('AGENT · DONE'), findsOneWidget);
  });

  testWidgets('no pill without a job link', (tester) async {
    final _FakeJobs jobs = _FakeJobs(_job(NativeAgentJobStatus.running));
    await tester.pumpWidget(
      hostTab(
        () => QueueListRow(
          recording: makeRecording(id: 'plain'),
          selected: false,
          isEnriching: false,
          density: QueueDensity.comfortable,
          onTap: () {},
          agentJobs: jobs,
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('AGENT'), findsNothing);
    expect(jobs.reads, 0);
  });
}
