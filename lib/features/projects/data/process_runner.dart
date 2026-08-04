import 'dart:convert';
import 'dart:io';

class CommandResult {
  const CommandResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

/// Test seam around process creation.
abstract interface class ProcessRunner {
  Future<CommandResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  });
}

class SystemProcessRunner implements ProcessRunner {
  const SystemProcessRunner();

  @override
  Future<CommandResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    // Deliberately no shell and no TERM_PROGRAM override. Session creation is
    // performed by Ghostty after the user's explicit launch action.
    final ProcessResult result = await Process.run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      runInShell: false,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    return CommandResult(
      exitCode: result.exitCode,
      stdout: result.stdout as String,
      stderr: result.stderr as String,
    );
  }
}
