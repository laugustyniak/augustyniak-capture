import '../domain/agent_session_launcher.dart';
import '../domain/native_agent_types.dart';
import 'native_agent_jobs.dart';

/// Uses native jobs for background work and preserves Zellij for windows.
class HybridAgentSessionLauncher implements AgentSessionLauncher {
  const HybridAgentSessionLauncher({
    required AgentSessionLauncher windowed,
    required NativeAgentJobs jobs,
  }) : _windowed = windowed,
       _jobs = jobs;

  final AgentSessionLauncher _windowed;
  final NativeAgentJobs _jobs;

  @override
  Future<AgentSessionLaunchResult> launch(
    AgentSessionLaunchRequest request,
  ) async {
    if (!request.detached) {
      // A configured command is only understood by the native adapter.
      if (request.executable != null) {
        throw const AgentSessionLaunchException(
          'A configured agent command can only run in the background.',
        );
      }
      return _windowed.launch(request);
    }
    final NativeAgentJobHandle job = await _jobs.launch(request);
    return AgentSessionLaunchResult(
      sessionName: job.id,
      attachedToExistingSession: false,
      detached: true,
      job: job,
    );
  }

  @override
  Future<void> attach(String sessionName) => _windowed.attach(sessionName);
}
