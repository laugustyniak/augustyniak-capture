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
  DateTime? finishedAt,
}) => NativeAgentJob(
  handle: _handle,
  status: status,
  createdAt: DateTime.now().subtract(const Duration(minutes: 2)),
  finishedAt: finishedAt,
  workspacePath: '/work/project',
  logs: 'log output',
  result: result,
  conversationId: conversationId,
);

class _FakeJobs extends NativeAgentJobs {
  _FakeJobs(this.job) : super(jobsRoot: () async => Directory.systemTemp);

  NativeAgentJob? job;
  bool failReads = false;
  int reads = 0;
  final List<String> stopped = <String>[];

  @override
  Future<NativeAgentJob> read(String id) async {
    reads++;
    if (failReads || job == null) throw const FormatException('gone');
    return job!;
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
          child: AgentRunsSection(
            recording: recording,
            jobs: jobs,
            pollInterval: const Duration(milliseconds: 100),
          ),
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
    expect(find.textContaining('02:0'), findsOneWidget);
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
        finishedAt: DateTime.now(),
      ),
    );
    await mountSection(tester, _withJob(), jobs);

    expect(find.text('PR #42'), findsOneWidget);
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
