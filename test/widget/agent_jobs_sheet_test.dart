import 'dart:io';

import 'package:augustyniak_capture/features/projects/data/native_agent_jobs.dart';
import 'package:augustyniak_capture/features/projects/domain/native_agent_types.dart';
import 'package:augustyniak_capture/features/projects/presentation/agent_jobs_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('job details expose result, stop and exact follow-up', (
    WidgetTester tester,
  ) async {
    final _FakeJobs jobs = _FakeJobs();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(body: AgentJobsSheet(jobs: jobs)),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey<String>('agent-job-running')));
    await tester.pump();
    expect(find.text('live output'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('agent-job-stop')));
    await tester.pump();
    expect(jobs.stopped, <String>['running']);

    await tester.tap(find.text('ALL JOBS'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('agent-job-completed')));
    await tester.pump();
    expect(find.text('finished result'), findsOneWidget);
    expect(find.text('APPROVALS OFF'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('agent-job-follow-up')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey<String>('agent-job-follow-up-input')),
      'continue exactly here',
    );
    await tester.tap(find.text('SEND'));
    await tester.pump();

    expect(jobs.followedUp, <String, String>{
      'parent': 'completed',
      'prompt': 'continue exactly here',
    });
  });
}

class _FakeJobs extends NativeAgentJobs {
  _FakeJobs() : super(jobsRoot: () async => Directory.systemTemp);

  final List<String> stopped = <String>[];
  Map<String, String>? followedUp;
  final List<NativeAgentJob> values = <NativeAgentJob>[
    NativeAgentJob(
      handle: const NativeAgentJobHandle(
        id: 'running',
        backend: NativeAgentBackend.codex,
      ),
      status: NativeAgentJobStatus.running,
      createdAt: DateTime(2026),
      workspacePath: '/work/project',
      logs: 'live output',
      conversationId: 'thread-running',
    ),
    NativeAgentJob(
      handle: const NativeAgentJobHandle(
        id: 'completed',
        backend: NativeAgentBackend.claude,
      ),
      status: NativeAgentJobStatus.completed,
      createdAt: DateTime(2026),
      workspacePath: '/work/project',
      logs: 'done log',
      conversationId: 'session-completed',
      result: 'finished result',
      exitCode: 0,
      approvalsOff: true,
    ),
  ];

  @override
  Future<List<NativeAgentJob>> list() async => values;

  @override
  Future<void> stop(String id) async {
    stopped.add(id);
  }

  @override
  Future<NativeAgentJobHandle> followUp(
    String parentJobId,
    String prompt,
  ) async {
    followedUp = <String, String>{'parent': parentJobId, 'prompt': prompt};
    return const NativeAgentJobHandle(
      id: 'running',
      backend: NativeAgentBackend.codex,
    );
  }
}
