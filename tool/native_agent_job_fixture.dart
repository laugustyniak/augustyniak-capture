import 'dart:io';

import 'package:augustyniak_capture/features/projects/data/executable_resolver.dart';
import 'package:augustyniak_capture/features/projects/data/native_agent_jobs.dart';
import 'package:augustyniak_capture/features/projects/domain/agent_session_launcher.dart';

class _ExactExecutable implements ExecutableResolver {
  const _ExactExecutable(this.path);

  final String path;

  @override
  Future<String?> resolve(String name) async => path;
}

Future<void> main(List<String> arguments) async {
  if (arguments.length != 3) {
    stderr.writeln('usage: native_agent_job_fixture JOBS WORKSPACE EXECUTABLE');
    exitCode = 64;
    return;
  }
  final NativeAgentJobs jobs = NativeAgentJobs(
    jobsRoot: () async => Directory(arguments[0]),
    executables: _ExactExecutable(arguments[2]),
  );
  final handle = await jobs.launch(
    AgentSessionLaunchRequest(
      projectId: 'owner-exit-fixture',
      projectName: 'Owner exit fixture',
      repoPath: arguments[1],
      agent: ProjectAgent.codex,
      prompt: 'continue after this process exits',
      detached: true,
    ),
  );
  stdout.writeln(handle.id);
}
