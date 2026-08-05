import 'dart:io';

import 'package:augustyniak_capture/features/projects/data/executable_resolver.dart';
import 'package:augustyniak_capture/features/projects/data/process_runner.dart';
import 'package:flutter_test/flutter_test.dart';

class _Invocation {
  const _Invocation(this.executable, this.arguments);

  final String executable;
  final List<String> arguments;
}

class _FakeProcessRunner implements ProcessRunner {
  _FakeProcessRunner({this.stdout = '', this.exitCode = 0});

  final String stdout;
  final int exitCode;
  final List<_Invocation> invocations = <_Invocation>[];

  @override
  Future<CommandResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    invocations.add(_Invocation(executable, List<String>.of(arguments)));
    return CommandResult(exitCode: exitCode, stdout: stdout, stderr: '');
  }
}

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('augustyniak_capture_bins_');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// Creates `<root>/<directory>/<name>` and answers its path.
  String install(String directory, String name) {
    final Directory bin = Directory('${root.path}/$directory')
      ..createSync(recursive: true);
    final File file = File('${bin.path}/$name')..writeAsStringSync('');
    return file.path;
  }

  test('takes the process PATH first, and only a file that exists', () async {
    final String real = install('opt/bin', 'zellij');
    install('opt/bin', 'ignored');
    final _FakeProcessRunner runner = _FakeProcessRunner();
    final PathExecutableResolver resolver = PathExecutableResolver(
      processRunner: runner,
      // A directory that does not exist leads, because a real PATH is full of
      // them and a name must not resolve to a path that is merely plausible.
      environment: <String, String>{
        'PATH': '${root.path}/nowhere:${root.path}/opt/bin',
      },
    );

    expect(await resolver.resolve('zellij'), real);
    // The cheap answer costs no process at all.
    expect(runner.invocations, isEmpty);
  });

  test('falls back to conventional install directories', () async {
    final String claude = install('.local/bin', 'claude');
    final _FakeProcessRunner runner = _FakeProcessRunner();
    final PathExecutableResolver resolver = PathExecutableResolver(
      processRunner: runner,
      // What a bundled macOS app actually gets: no Homebrew, no ~/.local/bin.
      environment: <String, String>{
        'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
        'HOME': root.path,
      },
    );

    expect(await resolver.resolve('claude'), claude);
    expect(runner.invocations, isEmpty);
  });

  test('asks the login shell last, and passes the name as data', () async {
    final String tool = install('managed/bin', 'codex');
    final _FakeProcessRunner runner = _FakeProcessRunner(
      // A login shell prints whatever the user's rc files print; the answer is
      // the last absolute path, not the whole of stdout.
      stdout: 'Welcome back!\n$tool\n',
    );
    final PathExecutableResolver resolver = PathExecutableResolver(
      processRunner: runner,
      environment: <String, String>{
        'PATH': '/usr/bin:/bin',
        'HOME': root.path,
        'SHELL': '/bin/zsh',
      },
      conventionalDirectories: <String>['${root.path}/.local/bin'],
    );

    expect(await resolver.resolve('codex'), tool);
    expect(runner.invocations.single.executable, '/bin/zsh');
    // The name arrives as `$0`, never interpolated into the command string, so
    // a shell has nothing in it left to parse.
    expect(runner.invocations.single.arguments, <String>[
      '-lc',
      r'command -v "$0"',
      'codex',
    ]);
  });

  test('a shell answer that no longer exists is not an answer', () async {
    final _FakeProcessRunner runner = _FakeProcessRunner(
      stdout: '${root.path}/uninstalled/codex\n',
    );
    final PathExecutableResolver resolver = PathExecutableResolver(
      processRunner: runner,
      environment: <String, String>{'PATH': '/usr/bin', 'HOME': root.path},
      conventionalDirectories: <String>['${root.path}/.local/bin'],
    );

    expect(await resolver.resolve('codex'), isNull);
  });

  test('resolves once per name, misses included', () async {
    final _FakeProcessRunner runner = _FakeProcessRunner(exitCode: 1);
    final PathExecutableResolver resolver = PathExecutableResolver(
      processRunner: runner,
      environment: <String, String>{'PATH': '/usr/bin', 'HOME': root.path},
      conventionalDirectories: <String>['${root.path}/.local/bin'],
    );

    expect(await resolver.resolve('codex'), isNull);
    expect(await resolver.resolve('codex'), isNull);

    // A miss is cached too: it is reported to the user as a missing tool, and
    // retrying would put a login-shell start-up behind every tap of a control
    // that has already failed once.
    expect(runner.invocations, hasLength(1));
  });
}
