import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../../core/security/owner_only_file.dart';
import '../../../core/security/symlink_guard.dart';
import '../domain/agent_session_launcher.dart';
import '../domain/native_agent_job.dart';
import '../domain/native_agent_types.dart';
import 'executable_resolver.dart';

const int _maxLogBytes = 256 * 1024;
const int _parseHeadBytes = 64 * 1024;

class NativeAgentJob {
  const NativeAgentJob({
    required this.handle,
    required this.status,
    required this.createdAt,
    required this.workspacePath,
    required this.logs,
    this.projectName,
    this.approvalsOff = false,
    this.promptAccepted = false,
    this.errorBeforePromptAccepted = false,
    this.conversationId,
    this.result,
    this.error,
    this.exitCode,
    this.parentJobId,
  });
  final NativeAgentJobHandle handle;
  final NativeAgentJobStatus status;
  final DateTime createdAt;
  final String workspacePath;
  final String logs;
  final String? projectName;
  final bool approvalsOff;
  final bool promptAccepted;
  final bool errorBeforePromptAccepted;
  final String? conversationId;
  final String? result;
  final String? error;
  final int? exitCode;
  final String? parentJobId;
  bool get isTerminal => switch (status) {
    NativeAgentJobStatus.completed ||
    NativeAgentJobStatus.failed ||
    NativeAgentJobStatus.stopped ||
    NativeAgentJobStatus.lost => true,
    _ => false,
  };
}

/// Persists and supervises native background agent jobs outside repositories.
class NativeAgentJobs {
  NativeAgentJobs({
    required Future<Directory> Function() jobsRoot,
    ExecutableResolver? executables,
    String Function()? idFactory,
    DateTime Function()? now,
    Map<String, String>? environment,
    this.startupTimeout = const Duration(seconds: 30),
    this.pollInterval = const Duration(milliseconds: 50),
  }) : _jobsRoot = jobsRoot,
       _executables = executables ?? PathExecutableResolver(),
       _idFactory = idFactory ?? (() => const Uuid().v4()),
       _now = now ?? DateTime.now,
       _environment = environment ?? Platform.environment;

  final Future<Directory> Function() _jobsRoot;
  final ExecutableResolver _executables;
  final String Function() _idFactory;
  final DateTime Function() _now;
  final Map<String, String> _environment;
  final Duration startupTimeout;
  final Duration pollInterval;
  final Set<String> _continuationsInFlight = <String>{};

  Future<NativeAgentJobHandle> launch(
    AgentSessionLaunchRequest request, {
    String? parentJobId,
    String? expectedConversationId,
  }) async {
    if (!Platform.isLinux && !Platform.isMacOS) {
      throw const AgentSessionLaunchException(
        'Native background jobs require macOS or Linux.',
      );
    }
    final String prompt = request.prompt?.trim() ?? '';
    if (prompt.isEmpty) {
      throw const AgentSessionLaunchException(
        'A background job needs an opening prompt.',
      );
    }
    final Directory workspace = Directory(request.repoPath);
    if (!await workspace.exists()) {
      throw AgentSessionLaunchException(
        'Repository directory does not exist: ${request.repoPath}',
      );
    }
    final NativeAgentBackend backend = nativeBackendFor(request.agent);
    final String? executable = await _executables.resolve(
      request.agent.executable,
    );
    if (executable == null) {
      throw AgentSessionLaunchException(
        'Could not find `${request.agent.executable}` on this machine.',
      );
    }
    final String id = _idFactory();
    if (!isSafeNativeAgentJobId(id)) {
      throw const AgentSessionLaunchException(
        'Could not create a safe job id.',
      );
    }
    final Directory root = await _prepareRoot();
    final Directory directory = Directory(p.join(root.path, id));
    await refuseSymlink(directory.path);
    await directory.create();
    await restrictDirectoryToOwner(directory.path);
    final String nonce = const Uuid().v4().replaceAll('-', '');
    final NativeAgentInvocation invocation = buildNativeAgentInvocation(
      backend: backend,
      configuredArguments: request.arguments,
      prompt: prompt,
      conversationId: expectedConversationId,
    );
    final Map<String, dynamic> metadata = <String, dynamic>{
      'id': id,
      'backend': backend.name,
      'agent': request.agent.name,
      'projectId': request.projectId,
      'projectName': request.projectName,
      'workspacePath': workspace.absolute.path,
      'createdAt': _now().toUtc().toIso8601String(),
      'configuredArguments': request.arguments,
      'prompt': prompt,
    };
    if (parentJobId != null) metadata['parentJobId'] = parentJobId;
    if (expectedConversationId != null) {
      metadata['expectedConversationId'] = expectedConversationId;
    }
    await _writePrivate(
      File(p.join(directory.path, 'request.json')),
      jsonEncode(metadata),
    );
    await _writePrivate(
      File(p.join(directory.path, 'stdin')),
      invocation.stdin,
    );
    await _writePrivate(File(p.join(directory.path, 'nonce')), nonce);
    await _writePrivate(File(p.join(directory.path, 'stdout.jsonl')), '');
    await _writePrivate(File(p.join(directory.path, 'stderr')), '');
    await _writeStatus(directory, NativeAgentJobStatus.starting);
    final String script = await _supervisorPath(root);
    try {
      await Process.start(
        '/bin/sh',
        <String>[
          script,
          directory.path,
          nonce,
          await _currentProcessGroup(),
          executable,
          ...invocation.arguments,
        ],
        workingDirectory: workspace.absolute.path,
        mode: ProcessStartMode.detached,
        runInShell: false,
        includeParentEnvironment: false,
        environment: <String, String>{
          ..._environment,
          'PATH': <String>[
            p.dirname(executable),
            if ((_environment['PATH'] ?? '').isNotEmpty) _environment['PATH']!,
          ].join(':'),
        },
      );
    } on ProcessException catch (error) {
      await _writeStatus(directory, NativeAgentJobStatus.failed);
      await _writePrivate(
        File(p.join(directory.path, 'startup-error')),
        error.message,
      );
      throw AgentSessionLaunchException(
        'Could not start the background supervisor: ${error.message}',
      );
    }

    final DateTime deadline = _now().add(startupTimeout);
    while (_now().isBefore(deadline)) {
      final NativeAgentJob job = await read(id);
      final String? providerId = job.conversationId;
      if (job.promptAccepted &&
          !job.errorBeforePromptAccepted &&
          providerId != null) {
        await _writePrivate(
          File(p.join(directory.path, 'conversation-id')),
          providerId,
        );
        if (!job.isTerminal) {
          await _writeStatus(directory, NativeAgentJobStatus.running);
        }
        return NativeAgentJobHandle(id: id, backend: backend);
      }
      if (job.error != null ||
          job.status == NativeAgentJobStatus.failed ||
          job.status == NativeAgentJobStatus.lost ||
          job.status == NativeAgentJobStatus.stopped) {
        if (job.error != null) {
          await _writeStatus(directory, NativeAgentJobStatus.failed);
        }
        throw AgentSessionLaunchException(
          job.error ??
              (job.logs.trim().isEmpty
                  ? 'The agent exited before accepting the prompt.'
                  : job.logs.trim()),
        );
      }
      if (job.isTerminal) {
        throw AgentSessionLaunchException(
          job.error ??
              (job.logs.trim().isEmpty
                  ? 'The agent exited before accepting the prompt.'
                  : job.logs.trim()),
        );
      }
      await Future<void>.delayed(pollInterval);
    }
    throw AgentSessionLaunchException(
      'The agent did not confirm the prompt before the startup timeout. Job `$id` remains available in Jobs for diagnosis.',
    );
  }

  Future<List<NativeAgentJob>> list() async {
    final Directory root = await _prepareRoot();
    final List<NativeAgentJob> jobs = <NativeAgentJob>[];
    await for (final FileSystemEntity entity in root.list(followLinks: false)) {
      if (entity is! Directory ||
          !isSafeNativeAgentJobId(p.basename(entity.path)) ||
          await FileSystemEntity.isLink(entity.path)) {
        continue;
      }
      try {
        jobs.add(await read(p.basename(entity.path)));
      } on FileSystemException {
        // One damaged job does not hide the others.
      } on FormatException {
        // One damaged job does not hide the others.
      }
    }
    jobs.sort(
      (NativeAgentJob a, NativeAgentJob b) =>
          b.createdAt.compareTo(a.createdAt),
    );
    return jobs;
  }

  Future<NativeAgentJob> read(String id) async {
    final Directory directory = await _jobDirectory(id);
    final Map<String, dynamic> metadata = await _metadata(directory);
    final NativeAgentBackend? backend = _backend(metadata['backend']);
    final DateTime? createdAt = DateTime.tryParse('${metadata['createdAt']}');
    final Object? workspace = metadata['workspacePath'];
    final Object? configuredArguments = metadata['configuredArguments'];
    if (backend == null || createdAt == null || workspace is! String) {
      throw const FormatException('Invalid native agent job metadata.');
    }
    final NativeAgentOutput parsed = parseNativeAgentOutput(
      backend,
      await _parseOutputLines(directory),
    );
    final String? persistedId = await _readOptional(
      File(p.join(directory.path, 'conversation-id')),
    );
    final int? exitCode = int.tryParse(
      (await _readOptional(File(p.join(directory.path, 'exit-code')))) ?? '',
    );
    NativeAgentJobStatus status = await _readStatus(directory);
    final String? expectedId = metadata['expectedConversationId'] is String
        ? (metadata['expectedConversationId'] as String).trim()
        : null;
    final List<String> observedIds = <String>[
      ...parsed.observedConversationIds,
      if (persistedId?.trim().isNotEmpty == true) persistedId!.trim(),
    ];
    String? mismatchedId;
    if (expectedId != null && expectedId.isNotEmpty) {
      for (final String value in observedIds) {
        if (value != expectedId) {
          mismatchedId = value;
          break;
        }
      }
    }
    String? identityError;
    if (mismatchedId != null) {
      identityError =
          'The provider resumed `$mismatchedId` instead of the requested '
          '`$expectedId`.';
      await _requestStop(directory);
      await _writePrivate(
        File(p.join(directory.path, 'startup-error')),
        identityError,
      );
      await _writeStatus(directory, NativeAgentJobStatus.failed);
      status = NativeAgentJobStatus.failed;
    }
    if (!_terminal(status) && !await _supervisorAlive(directory)) {
      if (exitCode != null) {
        status = await _validStopRequested(directory)
            ? NativeAgentJobStatus.stopped
            : exitCode == 0
            ? NativeAgentJobStatus.completed
            : NativeAgentJobStatus.failed;
      } else if (status != NativeAgentJobStatus.starting ||
          _now().difference(createdAt.toLocal()) >= startupTimeout) {
        status = NativeAgentJobStatus.lost;
      }
    }
    final String stdout = await _tail(
      File(p.join(directory.path, 'stdout.jsonl')),
      _maxLogBytes ~/ 2,
    );
    final String stderr = await _tail(
      File(p.join(directory.path, 'stderr')),
      _maxLogBytes ~/ 2,
    );
    String? error =
        identityError ??
        await _readOptional(File(p.join(directory.path, 'startup-error'))) ??
        parsed.error;
    if (status == NativeAgentJobStatus.completed && parsed.error != null) {
      status = NativeAgentJobStatus.failed;
    }
    if (status == NativeAgentJobStatus.completed && !parsed.terminal) {
      status = NativeAgentJobStatus.failed;
      error ??= 'The agent exited without a terminal result event.';
    }
    return NativeAgentJob(
      handle: NativeAgentJobHandle(id: id, backend: backend),
      status: status,
      createdAt: createdAt,
      workspacePath: workspace,
      projectName: metadata['projectName'] is String
          ? metadata['projectName'] as String
          : null,
      approvalsOff:
          configuredArguments is List &&
          configuredArguments.whereType<String>().any(
            (String argument) =>
                argument == '--dangerously-bypass-approvals-and-sandbox' ||
                argument == '--dangerously-skip-permissions',
          ),
      promptAccepted: parsed.promptAccepted,
      errorBeforePromptAccepted: parsed.errorBeforePromptAccepted,
      logs: <String>[
        if (stdout.trim().isNotEmpty) stdout.trimRight(),
        if (stderr.trim().isNotEmpty) stderr.trimRight(),
      ].join('\n'),
      conversationId: identityError != null
          ? null
          : persistedId?.trim().isNotEmpty == true
          ? persistedId!.trim()
          : parsed.conversationId,
      result: parsed.result,
      error: error,
      exitCode: exitCode,
      parentJobId: metadata['parentJobId'] is String
          ? metadata['parentJobId'] as String
          : null,
    );
  }

  Future<void> stop(String id) async {
    final Directory directory = await _jobDirectory(id);
    final NativeAgentJob job = await read(id);
    if (job.isTerminal) return;
    if (!await _supervisorAlive(directory)) {
      throw const AgentSessionLaunchException(
        'The background supervisor is no longer running.',
      );
    }
    final String nonce = (await File(
      p.join(directory.path, 'nonce'),
    ).readAsString()).trim();
    await _writeStatus(directory, NativeAgentJobStatus.stopping);
    await _writePrivate(File(p.join(directory.path, 'stop')), nonce);
  }

  Future<void> _requestStop(Directory directory) async {
    if (!await _supervisorAlive(directory)) return;
    final String? nonce = await _readOptional(
      File(p.join(directory.path, 'nonce')),
    );
    if (nonce?.trim().isEmpty != false) return;
    await _writePrivate(File(p.join(directory.path, 'stop')), nonce!.trim());
  }

  Future<bool> _validStopRequested(Directory directory) async {
    final String? nonce = await _readOptional(
      File(p.join(directory.path, 'nonce')),
    );
    final String? stop = await _readOptional(
      File(p.join(directory.path, 'stop')),
    );
    return nonce != null && stop?.trim() == nonce.trim();
  }

  Future<NativeAgentJobHandle> followUp(String id, String prompt) async {
    final NativeAgentJob parent = await read(id);
    if (!parent.isTerminal || parent.conversationId == null) {
      throw const AgentSessionLaunchException(
        'Follow-up is available after the job finishes with a conversation id.',
      );
    }
    final Map<String, dynamic> metadata = await _metadata(
      await _jobDirectory(id),
    );
    final ProjectAgent? agent = _agent(metadata['agent']);
    final Object? arguments = metadata['configuredArguments'];
    if (agent == null || arguments is! List) {
      throw const AgentSessionLaunchException(
        'The saved job cannot be continued by this version.',
      );
    }
    final String key = '${parent.handle.backend.name}:${parent.conversationId}';
    if (!_continuationsInFlight.add(key)) {
      throw const AgentSessionLaunchException(
        'A follow-up to this conversation is already running.',
      );
    }
    try {
      if (await _hasActiveContinuation(
        parent.handle.backend,
        parent.conversationId!,
      )) {
        throw const AgentSessionLaunchException(
          'A follow-up to this conversation is already running.',
        );
      }
      return await launch(
        AgentSessionLaunchRequest(
          projectId: '${metadata['projectId']}',
          projectName: '${metadata['projectName']}',
          repoPath: parent.workspacePath,
          agent: agent,
          arguments: arguments.whereType<String>().toList(growable: false),
          prompt: prompt,
          detached: true,
        ),
        parentJobId: id,
        expectedConversationId: parent.conversationId,
      );
    } finally {
      _continuationsInFlight.remove(key);
    }
  }

  Future<bool> _hasActiveContinuation(
    NativeAgentBackend backend,
    String conversationId,
  ) async {
    final Directory root = await _prepareRoot();
    await for (final FileSystemEntity entity in root.list(followLinks: false)) {
      if (entity is! Directory ||
          !isSafeNativeAgentJobId(p.basename(entity.path))) {
        continue;
      }
      try {
        final Map<String, dynamic> metadata = await _metadata(entity);
        if (metadata['backend'] != backend.name ||
            metadata['expectedConversationId'] != conversationId) {
          continue;
        }
        if (!(await read(p.basename(entity.path))).isTerminal) return true;
      } on FileSystemException {
        continue;
      } on FormatException {
        continue;
      }
    }
    return false;
  }

  Future<Directory> _prepareRoot() async {
    final Directory root = await _jobsRoot();
    await refuseSymlink(root.path);
    if (!await root.exists()) {
      await root.create(recursive: true);
    }
    await restrictDirectoryToOwner(root.path);
    return root;
  }

  Future<Directory> _jobDirectory(String id) async {
    if (!isSafeNativeAgentJobId(id)) {
      throw const AgentSessionLaunchException('Unsafe background job handle.');
    }
    final Directory root = await _prepareRoot();
    final Directory directory = Directory(p.join(root.path, id));
    if (!p.isWithin(root.path, directory.path) ||
        await FileSystemEntity.isLink(directory.path) ||
        !await directory.exists()) {
      throw const AgentSessionLaunchException('Background job not found.');
    }
    return directory;
  }

  Future<Map<String, dynamic>> _metadata(Directory directory) async {
    final File file = File(p.join(directory.path, 'request.json'));
    await refuseSymlink(file.path);
    final Object? value = jsonDecode(await file.readAsString());
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Invalid native agent job metadata.');
    }
    return value;
  }

  Future<String> _supervisorPath(Directory root) async {
    final File file = File(p.join(root.path, 'supervisor-v1.sh'));
    await refuseSymlink(file.path);
    if (!await file.exists() ||
        await file.readAsString() != _supervisorScript) {
      await _atomicWrite(file, _supervisorScript);
    }
    return file.path;
  }

  Future<bool> _supervisorAlive(Directory directory) async {
    final String? raw = await _readOptional(
      File(p.join(directory.path, 'identity.json')),
    );
    if (raw == null) return false;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return false;
    }
    if (decoded is! Map<String, dynamic>) return false;
    final Object? supervisorPid = decoded['pid'];
    final Object? pgid = decoded['pgid'];
    final Object? nonce = decoded['nonce'];
    if (supervisorPid is! int || pgid is! int || nonce is! String) return false;
    final ProcessResult result = await Process.run('/bin/ps', <String>[
      '-o',
      'pgid=,args=',
      '-p',
      '$supervisorPid',
    ]);
    if (result.exitCode != 0) return false;
    final String output = '${result.stdout}'.trim();
    return RegExp('^\\s*$pgid\\s').hasMatch(output) &&
        output.contains(directory.path) &&
        output.contains(nonce);
  }

  Future<List<String>> _parseOutputLines(Directory directory) async {
    final File file = File(p.join(directory.path, 'stdout.jsonl'));
    if (!await file.exists()) return const <String>[];
    final int length = await file.length();
    if (length <= _parseHeadBytes + _maxLogBytes) {
      return const LineSplitter().convert(await file.readAsString());
    }
    final RandomAccessFile reader = await file.open();
    try {
      final String head = utf8.decode(
        await reader.read(_parseHeadBytes),
        allowMalformed: true,
      );
      await reader.setPosition(length - _maxLogBytes);
      String tail = utf8.decode(
        await reader.read(_maxLogBytes),
        allowMalformed: true,
      );
      final int firstNewline = tail.indexOf('\n');
      if (firstNewline >= 0) tail = tail.substring(firstNewline + 1);
      return <String>[
        ...const LineSplitter().convert(head),
        ...const LineSplitter().convert(tail),
      ];
    } finally {
      await reader.close();
    }
  }

  Future<String> _tail(File file, int bytes) async {
    if (!await file.exists()) return '';
    final int length = await file.length();
    final RandomAccessFile reader = await file.open();
    try {
      await reader.setPosition(length > bytes ? length - bytes : 0);
      return utf8.decode(await reader.read(bytes), allowMalformed: true);
    } finally {
      await reader.close();
    }
  }

  Future<void> _writeStatus(Directory directory, NativeAgentJobStatus status) =>
      _atomicWrite(File(p.join(directory.path, 'status')), status.name);
  Future<NativeAgentJobStatus> _readStatus(Directory directory) async {
    final String? value = await _readOptional(
      File(p.join(directory.path, 'status')),
    );
    return NativeAgentJobStatus.values.firstWhere(
      (NativeAgentJobStatus status) => status.name == value?.trim(),
      orElse: () => NativeAgentJobStatus.lost,
    );
  }

  Future<void> _writePrivate(File file, String value) async {
    await refuseSymlink(file.path);
    await file.writeAsString(value, flush: true);
    await restrictToOwner(file.path);
  }

  Future<void> _atomicWrite(File file, String value) async {
    await refuseSymlink(file.path);
    final File temporary = File(
      '${file.path}.${const Uuid().v4().replaceAll('-', '')}.tmp',
    );
    await refuseSymlink(temporary.path);
    await temporary.writeAsString(value, flush: true);
    await restrictToOwner(temporary.path);
    await temporary.rename(file.path);
  }

  Future<String?> _readOptional(File file) async {
    await refuseSymlink(file.path);
    return await file.exists() ? file.readAsString() : null;
  }

  Future<String> _currentProcessGroup() async {
    final ProcessResult result = await Process.run('/bin/ps', <String>[
      '-o',
      'pgid=',
      '-p',
      '$pid',
    ]);
    return result.exitCode == 0 ? '${result.stdout}'.trim() : '-1';
  }

  static bool _terminal(NativeAgentJobStatus status) => switch (status) {
    NativeAgentJobStatus.completed ||
    NativeAgentJobStatus.failed ||
    NativeAgentJobStatus.stopped ||
    NativeAgentJobStatus.lost => true,
    _ => false,
  };
  static NativeAgentBackend? _backend(Object? value) {
    for (final NativeAgentBackend backend in NativeAgentBackend.values) {
      if (backend.name == value) return backend;
    }
    return null;
  }

  static ProjectAgent? _agent(Object? value) {
    for (final ProjectAgent agent in ProjectAgent.values) {
      if (agent.name == value) return agent;
    }
    return null;
  }
}

const String _supervisorScript = r'''#!/bin/sh
set -u
umask 077
job_dir=$1
nonce=$2
parent_pgid=$3
executable=$4
shift 4
write_marker() {
  marker=$1
  value=$2
  printf '%s' "$value" > "$job_dir/$marker.tmp"
  mv -f "$job_dir/$marker.tmp" "$job_dir/$marker"
}
supervisor_pid=$$
supervisor_pgid=$(/bin/ps -o pgid= -p "$$" | tr -d ' ')
if [ -z "$supervisor_pgid" ] || [ "$supervisor_pgid" = "$parent_pgid" ]; then
  write_marker startup-error 'The detached supervisor did not receive its own process group.'
  write_marker exit-code 125
  write_marker status failed
  exit 125
fi
printf '{"pid":%s,"pgid":%s,"nonce":"%s"}' "$supervisor_pid" "$supervisor_pgid" "$nonce" > "$job_dir/identity.json.tmp"
mv -f "$job_dir/identity.json.tmp" "$job_dir/identity.json"
"$executable" "$@" < "$job_dir/stdin" >> "$job_dir/stdout.jsonl" 2>> "$job_dir/stderr" &
child=$!
trap '' TERM
(
  while kill -0 "$child" 2>/dev/null; do
    if [ -f "$job_dir/stop" ] && [ "$(sed -n '1p' "$job_dir/stop")" = "$nonce" ]; then
      write_marker status stopping
      kill -TERM -"$supervisor_pgid" 2>/dev/null || true
      exit 0
    fi
    sleep 0.1
  done
) &
watcher=$!
set +e
wait "$child"
code=$?
kill "$watcher" 2>/dev/null || true
wait "$watcher" 2>/dev/null || true
write_marker exit-code "$code"
if [ -f "$job_dir/stop" ] && [ "$(sed -n '1p' "$job_dir/stop")" = "$nonce" ]; then
  write_marker status stopped
elif [ "$code" -eq 0 ]; then
  write_marker status completed
else
  write_marker status failed
fi
''';
