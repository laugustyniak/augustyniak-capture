import 'dart:convert';
import 'dart:io';

import 'package:augustyniak_capture/features/projects/data/executable_resolver.dart';
import 'package:augustyniak_capture/features/projects/data/native_agent_jobs.dart';
import 'package:augustyniak_capture/features/projects/data/process_runner.dart';
import 'package:augustyniak_capture/features/projects/domain/agent_session_launcher.dart';
import 'package:augustyniak_capture/features/projects/domain/native_agent_types.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _Resolver implements ExecutableResolver {
  _Resolver(this.path);

  final String path;

  @override
  Future<String?> resolve(String name) async => path;
}

class _CompletingProcessRunner implements ProcessRunner {
  _CompletingProcessRunner(this.completeJob);

  final Future<void> Function() completeJob;
  bool _completed = false;

  @override
  Future<CommandResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    if (!_completed) {
      _completed = true;
      await completeJob();
    }
    return const CommandResult(exitCode: 1, stdout: '', stderr: '');
  }
}

class _CountingJobs extends NativeAgentJobs {
  _CountingJobs(Directory root)
    : super(
        jobsRoot: () async => root,
        executables: _Resolver('/bin/true'),
        watchInterval: const Duration(milliseconds: 20),
        // Never lost within the test, so the job stays non-terminal.
        startupTimeout: const Duration(hours: 1),
      );

  int peeks = 0;

  @override
  Future<NativeAgentJob> peek(String id) {
    peeks++;
    return super.peek(id);
  }
}

void main() {
  if (!Platform.isLinux && !Platform.isMacOS) return;
  late Directory temp;
  late Directory jobsRoot;
  late Directory workspace;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('native-agent-jobs-test-');
    jobsRoot = Directory(p.join(temp.path, 'agent-jobs'));
    workspace = Directory(p.join(temp.path, 'workspace'))..createSync();
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  NativeAgentJobs manager(File executable) => NativeAgentJobs(
    jobsRoot: () async => jobsRoot,
    executables: _Resolver(executable.path),
    startupTimeout: const Duration(seconds: 5),
    pollInterval: const Duration(milliseconds: 20),
  );

  AgentSessionLaunchRequest request({required String prompt}) =>
      AgentSessionLaunchRequest(
        projectId: 'project',
        projectName: 'Project',
        repoPath: workspace.path,
        agent: ProjectAgent.codex,
        prompt: prompt,
        detached: true,
      );

  test('a detached job persists output and survives a new manager', () async {
    final File executable = await _fixtureExecutable(temp, r'''
read prompt
printf '%s\n' '{"type":"thread.started","thread_id":"thread-1"}'
printf '%s\n' '{"type":"turn.started"}'
printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"finished"}}'
printf '%s\n' '{"type":"turn.completed"}'
printf '%s\n' "stderr: $prompt" >&2
''');
    final NativeAgentJobs first = manager(executable);

    final NativeAgentJobHandle handle = await first.launch(
      request(prompt: 'private prompt'),
    );
    final NativeAgentJobs reopened = manager(executable);
    final NativeAgentJob job = await _pollJob(
      reopened,
      handle.id,
      (NativeAgentJob value) => value.isTerminal,
    );

    expect(job.status, NativeAgentJobStatus.completed);
    expect(job.conversationId, 'thread-1');
    expect(job.result, 'finished');
    expect(job.exitCode, 0);
    expect(job.logs, contains('stderr: private prompt'));
    expect(await _mode(jobsRoot.path), '700');
    expect(await _mode(p.join(jobsRoot.path, handle.id, 'stdin')), '600');
    expect(
      await File(
        p.join(jobsRoot.path, handle.id, 'request.json'),
      ).readAsString(),
      contains('private prompt'),
    );
  });

  test(
    'starting job uses the configured startup timeout before lost',
    () async {
      DateTime now = DateTime.utc(2026, 10, 23, 12);
      final DateTime createdAt = now.subtract(const Duration(seconds: 2));
      const String id = '00000000-0000-4000-8000-000000000001';
      final Directory directory = Directory(p.join(jobsRoot.path, id));
      await directory.create(recursive: true);
      await File(p.join(directory.path, 'request.json')).writeAsString(
        jsonEncode(<String, dynamic>{
          'id': id,
          'backend': 'codex',
          'agent': 'codex',
          'projectId': 'project',
          'projectName': 'Project',
          'workspacePath': workspace.path,
          'createdAt': createdAt.toIso8601String(),
          'configuredArguments': <String>[],
          'prompt': 'wait for startup',
        }),
      );
      await File(p.join(directory.path, 'status')).writeAsString('starting');
      final NativeAgentJobs jobs = NativeAgentJobs(
        jobsRoot: () async => jobsRoot,
        executables: _Resolver('/bin/true'),
        now: () => now,
        startupTimeout: const Duration(seconds: 5),
      );

      expect((await jobs.read(id)).status, NativeAgentJobStatus.starting);

      now = createdAt.add(const Duration(seconds: 6));
      expect((await jobs.read(id)).status, NativeAgentJobStatus.lost);
    },
  );

  test('dead supervisor refreshes the completed job snapshot', () async {
    final DateTime now = DateTime.utc(2026, 10, 23, 12);
    const String id = '00000000-0000-4000-8000-000000000002';
    final Directory directory = Directory(p.join(jobsRoot.path, id));
    await directory.create(recursive: true);
    await File(p.join(directory.path, 'request.json')).writeAsString(
      jsonEncode(<String, dynamic>{
        'id': id,
        'backend': 'codex',
        'agent': 'codex',
        'projectId': 'project',
        'projectName': 'Project',
        'workspacePath': workspace.path,
        'createdAt': now.toIso8601String(),
        'configuredArguments': <String>[],
        'prompt': 'finish during liveness check',
      }),
    );
    final File output = File(p.join(directory.path, 'stdout.jsonl'));
    await output.writeAsString(
      '{"type":"thread.started","thread_id":"snapshot-thread"}\n'
      '{"type":"turn.started"}\n',
    );
    await File(p.join(directory.path, 'status')).writeAsString('running');
    await File(
      p.join(directory.path, 'identity.json'),
    ).writeAsString('{"pid":123,"pgid":123,"nonce":"snapshot-nonce"}');
    final NativeAgentJobs jobs = NativeAgentJobs(
      jobsRoot: () async => jobsRoot,
      executables: _Resolver('/bin/true'),
      now: () => now,
      processRunner: _CompletingProcessRunner(() async {
        await output.writeAsString(
          '{"type":"item.completed","item":{"type":"agent_message","text":"fresh result"}}\n'
          '{"type":"turn.completed"}\n',
          mode: FileMode.append,
        );
        await File(p.join(directory.path, 'exit-code')).writeAsString('0');
        await File(p.join(directory.path, 'status')).writeAsString('completed');
      }),
    );

    final NativeAgentJob job = await jobs.read(id);

    expect(job.status, NativeAgentJobStatus.completed);
    expect(job.result, 'fresh result');
    expect(job.conversationId, 'snapshot-thread');
  });

  test(
    'stop is nonce-bound, stops the owned group and not another process',
    () async {
      final File executable = await _fixtureExecutable(temp, r'''
printf '%s\n' '{"type":"thread.started","thread_id":"thread-stop"}'
printf '%s\n' '{"type":"turn.started"}'
sh -c 'trap "exit 0" TERM; while :; do sleep 1; done' &
grandchild=$!
printf '%s' "$$" > "$PWD/fixture-child.pid"
printf '%s' "$grandchild" > "$PWD/fixture-grandchild.pid"
trap 'kill -TERM "$grandchild" 2>/dev/null; wait "$grandchild" 2>/dev/null; exit 0' TERM
n=0
while :; do n=$((n + 1)); printf 'tick%s\n' "$n" >&2; sleep 0.05; done
''');
      final Process outsider = await Process.start('/bin/sh', <String>[
        '-c',
        'trap "exit 0" TERM; while :; do sleep 1; done',
      ]);
      addTearDown(() => outsider.kill(ProcessSignal.sigkill));
      final NativeAgentJobs jobs = manager(executable);
      final NativeAgentJobHandle handle = await jobs.launch(
        request(prompt: 'x'),
      );

      final File stop = File(p.join(jobsRoot.path, handle.id, 'stop'));
      await stop.writeAsString('wrong-nonce');
      await _pollJob(
        jobs,
        handle.id,
        (NativeAgentJob value) => value.logs.contains('tick2'),
      );
      expect((await jobs.read(handle.id)).status, NativeAgentJobStatus.running);

      await jobs.stop(handle.id);
      final NativeAgentJob stopped = await _pollJob(
        jobs,
        handle.id,
        (NativeAgentJob value) => value.status == NativeAgentJobStatus.stopped,
      );
      expect(stopped.status, NativeAgentJobStatus.stopped);
      await File(
        p.join(jobsRoot.path, handle.id, 'status'),
      ).writeAsString('stopping');
      final NativeAgentJob recovered = await _pollJob(
        jobs,
        handle.id,
        (NativeAgentJob value) => value.status == NativeAgentJobStatus.stopped,
      );
      expect(recovered.exitCode, isNotNull);
      for (final String name in <String>[
        'fixture-child.pid',
        'fixture-grandchild.pid',
      ]) {
        final String ownedPid = await File(
          p.join(workspace.path, name),
        ).readAsString();
        expect(
          await Process.run('/bin/kill', <String>[
            '-0',
            ownedPid,
          ]).then((r) => r.exitCode),
          isNot(0),
          reason: name,
        );
      }
      expect(
        await Process.run('/bin/kill', <String>[
          '-0',
          '${outsider.pid}',
        ]).then((r) => r.exitCode),
        0,
      );
    },
  );

  test('follow-up uses the exact provider id and records its parent', () async {
    final File executable = await _fixtureExecutable(temp, r'''
read prompt
printf '%s\n' '{"type":"thread.started","thread_id":"thread-follow"}'
printf '%s\n' '{"type":"turn.started"}'
printf '%s\n' '{"type":"turn.completed"}'
''');
    final NativeAgentJobs jobs = manager(executable);
    final NativeAgentJobHandle first = await jobs.launch(
      request(prompt: 'first'),
    );
    await _pollJob(jobs, first.id, (NativeAgentJob value) => value.isTerminal);

    final NativeAgentJobHandle second = await jobs.followUp(first.id, 'second');
    final NativeAgentJob child = await _pollJob(
      jobs,
      second.id,
      (NativeAgentJob value) => value.isTerminal,
    );

    expect(child.parentJobId, first.id);
    expect(child.conversationId, 'thread-follow');
    final String savedRequest = await File(
      p.join(jobsRoot.path, second.id, 'request.json'),
    ).readAsString();
    expect(savedRequest, contains('thread-follow'));
    expect(savedRequest, isNot(contains('--last')));
  });

  test('only one active follow-up may use a provider conversation', () async {
    final File executable = await _fixtureExecutable(temp, r'''
read prompt
printf '%s\n' '{"type":"thread.started","thread_id":"thread-serial"}'
printf '%s\n' '{"type":"turn.started"}'
if [ "$prompt" = "first" ]; then
  printf '%s\n' '{"type":"turn.completed"}'
  exit 0
fi
trap 'exit 0' TERM
while [ ! -f "$PWD/finish-follow-up" ]; do sleep 0.02; done
printf '%s\n' '{"type":"turn.completed"}'
''');
    final NativeAgentJobs jobs = manager(executable);
    final NativeAgentJobHandle parent = await jobs.launch(
      request(prompt: 'first'),
    );
    await _pollJob(jobs, parent.id, (NativeAgentJob value) => value.isTerminal);
    final NativeAgentJobHandle active = await jobs.followUp(parent.id, 'stay');

    await expectLater(
      jobs.followUp(parent.id, 'overlap'),
      throwsA(
        isA<AgentSessionLaunchException>().having(
          (AgentSessionLaunchException error) => error.message,
          'message',
          contains('already running'),
        ),
      ),
    );
    await File(p.join(workspace.path, 'finish-follow-up')).writeAsString('go');
    await _pollJob(
      jobs,
      active.id,
      (NativeAgentJob value) => value.status == NativeAgentJobStatus.completed,
    );
  });

  test('the job completes after its launching Dart process exits', () async {
    final File executable = await _fixtureExecutable(temp, r'''
read prompt
printf '%s\n' '{"type":"thread.started","thread_id":"owner-exit"}'
printf '%s\n' '{"type":"turn.started"}'
sleep 0.3
printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"still alive"}}'
printf '%s\n' '{"type":"turn.completed"}'
''');
    final ProcessResult owner = await Process.run('dart', <String>[
      'run',
      'tool/native_agent_job_fixture.dart',
      jobsRoot.path,
      workspace.path,
      executable.path,
    ]);
    expect(owner.exitCode, 0, reason: '${owner.stderr}');
    final String id = (owner.stdout as String).trim().split('\n').last;

    final NativeAgentJob job = await _pollJob(
      manager(executable),
      id,
      (NativeAgentJob value) => value.isTerminal,
    );

    expect(job.status, NativeAgentJobStatus.completed);
    expect(job.result, 'still alive');
  });

  test('head id and tail result survive bounded large-output reads', () async {
    final File executable = await _fixtureExecutable(temp, r'''
read prompt
printf '%s\n' '{"type":"thread.started","thread_id":"large-thread"}'
printf '%s\n' '{"type":"turn.started"}'
i=0
while [ "$i" -lt 4000 ]; do
  printf '%s\n' '{"type":"item.started","item":{"type":"command_execution","command":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}}'
  i=$((i + 1))
done
printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"tail-result"}}'
printf '%s\n' '{"type":"turn.completed"}'
''');
    final NativeAgentJobs jobs = manager(executable);
    final NativeAgentJobHandle handle = await jobs.launch(
      request(prompt: 'large'),
    );
    final NativeAgentJob job = await _pollJob(
      jobs,
      handle.id,
      (NativeAgentJob value) => value.status == NativeAgentJobStatus.completed,
    );

    expect(job.conversationId, 'large-thread');
    expect(job.result, 'tail-result');
    expect(job.logs.length, lessThanOrEqualTo(256 * 1024 + 1));
  });

  test(
    'the resolved executable directory is prepended to child PATH',
    () async {
      final File helper = File(p.join(temp.path, 'fixture-helper'));
      await helper.writeAsString('#!/bin/sh\nexec /bin/sh "\$@"\n');
      await Process.run('chmod', <String>['700', helper.path]);
      final File executable = File(p.join(temp.path, 'env-cli'));
      await executable.writeAsString('''#!/usr/bin/env fixture-helper
read prompt
printf '%s\\n' '{"type":"thread.started","thread_id":"path-thread"}'
printf '%s\\n' '{"type":"turn.started"}'
printf '%s\\n' '{"type":"turn.completed"}'
''');
      await Process.run('chmod', <String>['700', executable.path]);
      final NativeAgentJobs jobs = NativeAgentJobs(
        jobsRoot: () async => jobsRoot,
        executables: _Resolver(executable.path),
        environment: const <String, String>{'PATH': '/usr/bin:/bin'},
        startupTimeout: const Duration(seconds: 2),
        pollInterval: const Duration(milliseconds: 20),
      );

      final NativeAgentJobHandle handle = await jobs.launch(
        request(prompt: 'path'),
      );
      final NativeAgentJob job = await _pollJob(
        jobs,
        handle.id,
        (NativeAgentJob value) => value.isTerminal,
      );

      expect(job.status, NativeAgentJobStatus.completed);
      expect(job.conversationId, 'path-thread');
    },
  );

  test(
    'a provider error after acknowledgement still marks the job failed',
    () async {
      final File executable = await _fixtureExecutable(temp, r'''
read prompt
printf '%s\n' '{"type":"thread.started","thread_id":"late-failure"}'
printf '%s\n' '{"type":"turn.started"}'
while [ ! -f "$PWD/allow-failure" ]; do sleep 0.02; done
printf '%s\n' '{"type":"turn.failed","error":{"message":"permission denied later"}}'
exit 0
''');
      final NativeAgentJobs jobs = manager(executable);

      final NativeAgentJobHandle handle = await jobs.launch(
        request(prompt: 'fail later'),
      );
      await File(p.join(workspace.path, 'allow-failure')).writeAsString('go');
      final NativeAgentJob job = await _pollJob(
        jobs,
        handle.id,
        (NativeAgentJob value) => value.isTerminal,
      );

      expect(job.status, NativeAgentJobStatus.failed);
      expect(job.error, contains('permission denied later'));
    },
  );

  test('provider init alone does not acknowledge the prompt', () async {
    final File executable = await _fixtureExecutable(temp, r'''
read prompt
printf '%s\n' '{"type":"thread.started","thread_id":"init-only"}'
touch "$PWD/init-observed"
while [ ! -f "$PWD/release-failure" ]; do sleep 0.02; done
printf '%s\n' '{"type":"turn.failed","error":{"message":"prompt rejected"}}'
exit 1
''');
    final NativeAgentJobs jobs = manager(executable);
    bool launchCompleted = false;
    final Future<NativeAgentJobHandle> launch = jobs
        .launch(request(prompt: 'must be accepted'))
        .whenComplete(() => launchCompleted = true);

    await _pollFile(File(p.join(workspace.path, 'init-observed')));
    final NativeAgentJob initialized = await _pollOnlyJob(
      jobs,
      (NativeAgentJob value) => value.conversationId == 'init-only',
    );
    expect(initialized.status, NativeAgentJobStatus.starting);
    expect(launchCompleted, isFalse);

    await File(p.join(workspace.path, 'release-failure')).writeAsString('go');
    await expectLater(
      launch,
      throwsA(
        isA<AgentSessionLaunchException>().having(
          (AgentSessionLaunchException error) => error.message,
          'message',
          contains('prompt rejected'),
        ),
      ),
    );
  });

  test('finishedAt is the supervisor-written terminal status only', () async {
    final File executable = await _fixtureExecutable(temp, r'''
read prompt
printf '%s\n' '{"type":"thread.started","thread_id":"t-1"}'
printf '%s\n' '{"type":"turn.started"}'
while [ ! -f "$PWD/finish" ]; do sleep 0.02; done
printf '%s\n' '{"type":"turn.completed"}'
''');
    final NativeAgentJobs jobs = manager(executable);
    final NativeAgentJobHandle handle = await jobs.launch(
      request(prompt: 'go'),
    );
    final NativeAgentJob running = await jobs.read(handle.id);
    expect(
      running.isTerminal,
      isFalse,
      reason: '${running.status} ${running.error}',
    );
    expect(running.finishedAt, isNull);

    await File(p.join(workspace.path, 'finish')).writeAsString('go');
    final NativeAgentJob done = await _pollJob(
      jobs,
      handle.id,
      (NativeAgentJob value) => value.isTerminal,
    );
    expect(done.status, NativeAgentJobStatus.completed);
    expect(done.finishedAt, isNotNull);
    expect(done.finishedAt!.isBefore(done.createdAt), isFalse);
  });

  test('finishedAt never precedes createdAt despite coarse mtimes', () async {
    const String id = '00000000-0000-4000-8000-000000000005';
    final Directory directory = Directory(p.join(jobsRoot.path, id));
    await directory.create(recursive: true);
    // Created "after" the status file's mtime, as happens when both fall in
    // one second and the filesystem truncates the mtime.
    final DateTime created = DateTime.now().add(const Duration(days: 1));
    await File(p.join(directory.path, 'request.json')).writeAsString(
      jsonEncode(<String, dynamic>{
        'id': id,
        'backend': 'codex',
        'agent': 'codex',
        'projectId': 'project',
        'projectName': 'Project',
        'workspacePath': workspace.path,
        'createdAt': created.toIso8601String(),
        'configuredArguments': <String>[],
        'prompt': 'x',
      }),
    );
    await File(p.join(directory.path, 'status')).writeAsString('failed');
    final NativeAgentJobs jobs = NativeAgentJobs(
      jobsRoot: () async => jobsRoot,
      executables: _Resolver('/bin/true'),
    );

    final NativeAgentJob job = await jobs.read(id);

    expect(job.status, NativeAgentJobStatus.failed);
    expect(job.finishedAt, isNotNull);
    expect(job.finishedAt!.isBefore(job.createdAt), isFalse);
  });

  test('a listener releasing the last watch leaves no timer', () async {
    const String id = '00000000-0000-4000-8000-000000000006';
    final Directory directory = Directory(p.join(jobsRoot.path, id));
    await directory.create(recursive: true);
    await File(p.join(directory.path, 'request.json')).writeAsString(
      jsonEncode(<String, dynamic>{
        'id': id,
        'backend': 'codex',
        'agent': 'codex',
        'projectId': 'project',
        'projectName': 'Project',
        'workspacePath': workspace.path,
        'createdAt': DateTime.now().toIso8601String(),
        'configuredArguments': <String>[],
        'prompt': 'x',
      }),
    );
    await File(p.join(directory.path, 'status')).writeAsString('starting');
    final _CountingJobs jobs = _CountingJobs(jobsRoot);
    late final NativeAgentJobWatch lease;
    lease = jobs.watch(id, () => lease.release());
    await _until(() => jobs.peeks >= 1);
    // Hold well past several intervals: a leaked timer would peek again.
    await Future<void>.delayed(jobs.watchInterval * 5);
    expect(jobs.peeks, 1);
  });

  test('a poller that gave up reports stale until resumed', () async {
    const String id = '00000000-0000-4000-8000-000000000008';
    await Directory(p.join(jobsRoot.path, id)).create(recursive: true);
    final _CountingJobs jobs = _CountingJobs(jobsRoot);
    final NativeAgentJobWatch lease = jobs.watch(id, () {});
    await _until(() => lease.stale);
    expect(lease.job, isNull);

    final NativeAgentJobWatch second = jobs.watch(id, () {});
    expect(second.stale, isFalse);
    await _until(() => second.stale);
    lease.release();
    second.release();
  });

  test('a transient read failure is retried and recovers', () async {
    const String id = '00000000-0000-4000-8000-000000000007';
    final Directory directory = Directory(p.join(jobsRoot.path, id));
    await directory.create(recursive: true);
    final _CountingJobs jobs = _CountingJobs(jobsRoot);
    int changes = 0;
    final NativeAgentJobWatch lease = jobs.watch(id, () => changes++);
    await _until(() => !lease.loading);
    expect(lease.job, isNull);

    await File(p.join(directory.path, 'request.json')).writeAsString(
      jsonEncode(<String, dynamic>{
        'id': id,
        'backend': 'codex',
        'agent': 'codex',
        'projectId': 'project',
        'projectName': 'Project',
        'workspacePath': workspace.path,
        'createdAt': DateTime.now().toIso8601String(),
        'configuredArguments': <String>[],
        'prompt': 'x',
      }),
    );
    await File(p.join(directory.path, 'status')).writeAsString('starting');
    await _until(() => lease.job != null);
    expect(lease.stale, isFalse);
    lease.release();
  });

  test('a derived lost status has no finishedAt', () async {
    const String id = '00000000-0000-4000-8000-000000000003';
    final Directory directory = Directory(p.join(jobsRoot.path, id));
    await directory.create(recursive: true);
    await File(p.join(directory.path, 'request.json')).writeAsString(
      jsonEncode(<String, dynamic>{
        'id': id,
        'backend': 'codex',
        'agent': 'codex',
        'projectId': 'project',
        'projectName': 'Project',
        'workspacePath': workspace.path,
        'createdAt': DateTime.utc(2026, 10, 23).toIso8601String(),
        'configuredArguments': <String>[],
        'prompt': 'x',
      }),
    );
    await File(p.join(directory.path, 'status')).writeAsString('running');
    final NativeAgentJobs jobs = NativeAgentJobs(
      jobsRoot: () async => jobsRoot,
      executables: _Resolver('/bin/true'),
      now: () => DateTime.utc(2026, 10, 24),
    );

    final NativeAgentJob job = await jobs.read(id);

    expect(job.status, NativeAgentJobStatus.lost);
    expect(job.finishedAt, isNull);
  });

  test('peek never enforces identity or writes; read still does', () async {
    final File executable = await _fixtureExecutable(temp, r'''
read prompt
printf '%s\n' '{"type":"thread.started","thread_id":"expected-thread"}'
printf '%s\n' '{"type":"turn.started"}'
while [ ! -f "$PWD/emit-mismatch" ]; do sleep 0.02; done
printf '%s\n' '{"type":"thread.started","thread_id":"wrong-thread"}'
while :; do sleep 1; done
''');
    final NativeAgentJobs jobs = manager(executable);
    final NativeAgentJobHandle handle = await jobs.launch(
      request(prompt: 'continue'),
      expectedConversationId: 'expected-thread',
    );
    await File(p.join(workspace.path, 'emit-mismatch')).writeAsString('go');
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 10));
    NativeAgentJob peeked = await jobs.peek(handle.id);
    while (!peeked.logs.contains('wrong-thread') &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      peeked = await jobs.peek(handle.id);
    }

    expect(peeked.logs, contains('wrong-thread'));
    expect(peeked.status, isNot(NativeAgentJobStatus.failed));
    expect(
      File(p.join(jobsRoot.path, handle.id, 'startup-error')).existsSync(),
      isFalse,
    );
    expect(
      File(p.join(jobsRoot.path, handle.id, 'stop')).existsSync(),
      isFalse,
    );

    final NativeAgentJob enforced = await jobs.read(handle.id);
    expect(enforced.status, NativeAgentJobStatus.failed);
  });

  test('watch shares one poller and stops with the last listener', () async {
    const String id = '00000000-0000-4000-8000-000000000004';
    final Directory directory = Directory(p.join(jobsRoot.path, id));
    await directory.create(recursive: true);
    await File(p.join(directory.path, 'request.json')).writeAsString(
      jsonEncode(<String, dynamic>{
        'id': id,
        'backend': 'codex',
        'agent': 'codex',
        'projectId': 'project',
        'projectName': 'Project',
        'workspacePath': workspace.path,
        'createdAt': DateTime.now().toIso8601String(),
        'configuredArguments': <String>[],
        'prompt': 'x',
      }),
    );
    await File(p.join(directory.path, 'status')).writeAsString('starting');
    final _CountingJobs jobs = _CountingJobs(jobsRoot);
    int a = 0;
    int b = 0;
    final NativeAgentJobWatch first = jobs.watch(id, () => a++);
    final NativeAgentJobWatch second = jobs.watch(id, () => b++);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(first.job, isNotNull);
    expect(first.job!.isTerminal, isFalse);
    expect(jobs.peeks, greaterThan(1));
    expect(a, b);

    first.release();
    second.release();
    final int after = jobs.peeks;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(jobs.peeks, after);
  });

  test('reopened jobs reject any mismatched provider id', () async {
    final File executable = await _fixtureExecutable(temp, r'''
read prompt
printf '%s\n' '{"type":"thread.started","thread_id":"expected-thread"}'
printf '%s\n' '{"type":"turn.started"}'
while [ ! -f "$PWD/emit-mismatch" ]; do sleep 0.02; done
printf '%s\n' '{"type":"thread.started","thread_id":"wrong-thread"}'
while :; do sleep 1; done
''');
    final NativeAgentJobs jobs = manager(executable);
    final NativeAgentJobHandle handle = await jobs.launch(
      request(prompt: 'continue'),
      expectedConversationId: 'expected-thread',
    );
    await File(p.join(workspace.path, 'emit-mismatch')).writeAsString('go');

    final NativeAgentJobs reopened = manager(executable);
    final NativeAgentJob failed = await _pollOnlyJob(
      reopened,
      (NativeAgentJob value) => value.error?.contains('wrong-thread') == true,
    );
    expect(failed.status, NativeAgentJobStatus.failed);
    expect(failed.conversationId, isNull);
    await expectLater(
      reopened.followUp(handle.id, 'retry'),
      throwsA(isA<AgentSessionLaunchException>()),
    );
    await _pollFile(File(p.join(jobsRoot.path, handle.id, 'exit-code')));
    final NativeAgentJob persisted = (await reopened.list()).single;
    expect(persisted.status, NativeAgentJobStatus.failed);
    expect(persisted.conversationId, isNull);
  });

  test('reopened jobs reject a mismatched persisted provider id', () async {
    final File executable = await _fixtureExecutable(temp, r'''
read prompt
printf '%s\n' '{"type":"thread.started","thread_id":"expected-thread"}'
printf '%s\n' '{"type":"turn.completed"}'
''');
    final NativeAgentJobs jobs = manager(executable);
    final NativeAgentJobHandle handle = await jobs.launch(
      request(prompt: 'continue'),
      expectedConversationId: 'expected-thread',
    );
    await _pollJob(jobs, handle.id, (NativeAgentJob value) => value.isTerminal);
    await File(
      p.join(jobsRoot.path, handle.id, 'conversation-id'),
    ).writeAsString('wrong-persisted');

    final NativeAgentJobs reopened = manager(executable);
    final NativeAgentJob failed = await reopened.read(handle.id);
    expect(failed.status, NativeAgentJobStatus.failed);
    expect(failed.error, contains('wrong-persisted'));
    expect(failed.conversationId, isNull);
    await expectLater(
      reopened.followUp(handle.id, 'retry'),
      throwsA(isA<AgentSessionLaunchException>()),
    );
  });

  test(
    'init followed by an early error never reports launch success',
    () async {
      final File executable = await _fixtureExecutable(temp, r'''
read prompt
printf '%s\n' '{"type":"thread.started","thread_id":"failed-thread"}'
printf '%s\n' '{"type":"turn.failed","error":{"message":"permission denied"}}'
exit 1
''');
      final NativeAgentJobs jobs = manager(executable);

      await expectLater(
        jobs.launch(request(prompt: 'fail')),
        throwsA(
          isA<AgentSessionLaunchException>().having(
            (AgentSessionLaunchException error) => error.message,
            'message',
            contains('permission denied'),
          ),
        ),
      );
      final NativeAgentJob saved = (await jobs.list()).single;
      expect(saved.status, NativeAgentJobStatus.failed);
    },
  );
}

Future<File> _fixtureExecutable(Directory root, String body) async {
  final File file = File(
    p.join(root.path, 'fixture-${DateTime.now().microsecondsSinceEpoch}.sh'),
  );
  await file.writeAsString('#!/bin/sh\n$body');
  await Process.run('chmod', <String>['700', file.path]);
  return file;
}

Future<void> _until(bool Function() done) async {
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) throw StateError('Timed out');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<NativeAgentJob> _pollJob(
  NativeAgentJobs jobs,
  String id,
  bool Function(NativeAgentJob value) done,
) async {
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    final NativeAgentJob value = await jobs.read(id);
    if (done(value)) return value;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  throw StateError('Timed out waiting for $id');
}

Future<NativeAgentJob> _pollOnlyJob(
  NativeAgentJobs jobs,
  bool Function(NativeAgentJob value) done,
) async {
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    final List<NativeAgentJob> values = await jobs.list();
    if (values.length == 1 && done(values.single)) return values.single;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  throw StateError('Timed out waiting for the only job');
}

Future<void> _pollFile(File file) async {
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    if (await file.exists()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  throw StateError('Timed out waiting for ${file.path}');
}

Future<String> _mode(String path) async {
  final int permissions = (await FileStat.stat(path)).mode & 0x1ff;
  return permissions.toRadixString(8);
}
