import 'package:augustyniak_capture/features/projects/data/executable_resolver.dart';
import 'package:augustyniak_capture/features/projects/data/terminal_launcher.dart';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Stands in for the machine's installed terminals. Nothing here may depend on
/// what the machine running the suite actually has: left implicit, whichever
/// terminal the developer installed decides which branch every test takes.
class _FakeResolver implements ExecutableResolver {
  const _FakeResolver({this.present = const <String>{}});

  final Set<String> present;

  @override
  Future<String?> resolve(String name) async =>
      present.contains(name) ? '/opt/fake/bin/$name' : null;
}

void main() {
  const String cwd = '/home/dev/project';
  const List<String> command = <String>['/opt/fake/bin/zellij', 'attach', 's1'];

  group('Linux terminal argument vectors', () {
    /// One case per terminal, asserted as a whole vector rather than by
    /// spot-checking a flag: the shapes differ in *where* the command goes
    /// (after `--`, after `-e`, bare at the end), and a case that put it in the
    /// wrong place would still contain every string a looser assertion checks.
    const Map<LinuxTerminal, List<String>> expected =
        <LinuxTerminal, List<String>>{
          LinuxTerminal.ghostty: <String>[
            '--working-directory=$cwd',
            '-e',
            ...command,
          ],
          LinuxTerminal.wezterm: <String>[
            'start',
            '--cwd',
            cwd,
            '--',
            ...command,
          ],
          LinuxTerminal.kitty: <String>['--directory', cwd, ...command],
          LinuxTerminal.alacritty: <String>[
            '--working-directory',
            cwd,
            '-e',
            ...command,
          ],
          LinuxTerminal.konsole: <String>['--workdir', cwd, '-e', ...command],
          LinuxTerminal.gnomeTerminal: <String>[
            '--working-directory=$cwd',
            '--',
            ...command,
          ],
          LinuxTerminal.xfce4Terminal: <String>[
            '--working-directory=$cwd',
            '-x',
            ...command,
          ],
        };

    for (final LinuxTerminal terminal in LinuxTerminal.values) {
      test('${terminal.executable} takes the command as a vector', () {
        final List<String> arguments = terminal.argumentsFor(cwd, command);
        expect(arguments, expected[terminal]);
        // The command is never collapsed into one shell string. The prompt an
        // agent is started with is the capture's own dictated text, so a form
        // that goes through a shell is a quoting bug waiting for an apostrophe.
        expect(arguments.last, command.last);
        expect(arguments, containsAll(command));
      });
    }

    test('every terminal has a case, so a new one cannot be forgotten', () {
      expect(expected.keys, unorderedEquals(LinuxTerminal.values));
    });
  });

  test('picks the first terminal that is installed', () async {
    final LinuxTerminalLauncher launcher = LinuxTerminalLauncher(
      executables: const _FakeResolver(
        present: <String>{'konsole', 'gnome-terminal'},
      ),
    );

    final ResolvedTerminal? terminal = await launcher.resolve();

    expect(terminal, isNotNull);
    expect(terminal!.executable, '/opt/fake/bin/konsole');
    expect(terminal.argumentsFor(cwd, command).take(2), <String>[
      '--workdir',
      cwd,
    ]);
  });

  test(
    'answers null when nothing is installed, and names the candidates',
    () async {
      final LinuxTerminalLauncher launcher = LinuxTerminalLauncher(
        executables: const _FakeResolver(),
      );

      expect(await launcher.resolve(), isNull);
      for (final LinuxTerminal terminal in LinuxTerminal.values) {
        expect(launcher.missingTerminalMessage, contains(terminal.executable));
      }
    },
  );

  test('macOS asks LaunchServices rather than looking for a binary', () async {
    // There is nothing to resolve ahead of time on macOS: `open` finds the
    // bundle, and a missing Ghostty surfaces as a non-zero exit from a command
    // that did run. So this launcher never answers null.
    final ResolvedTerminal? terminal = await MacOsGhosttyTerminalLauncher()
        .resolve();

    expect(terminal, isNotNull);
    expect(terminal!.executable, '/usr/bin/open');
    expect(terminal.argumentsFor(cwd, command), <String>[
      '-na',
      'Ghostty.app',
      '--args',
      '--working-directory=$cwd',
      '-e',
      ...command,
    ]);
  });

  group('this platform', () {
    // Asserted against the host rather than against a re-derived expression:
    // `expect(isSupportedPlatform, Platform.isMacOS || Platform.isLinux)` would
    // restate the implementation and pass whatever it says. These fail on the
    // Linux CI runner the moment the predicate goes back to macOS-only.
    test('Linux can start agent sessions', () {
      if (!Platform.isLinux) return;
      expect(TerminalLauncher.isSupportedPlatform, isTrue);
      expect(
        TerminalLauncher.forCurrentPlatform(),
        isA<LinuxTerminalLauncher>(),
      );
    });

    test('macOS can start agent sessions', () {
      if (!Platform.isMacOS) return;
      expect(TerminalLauncher.isSupportedPlatform, isTrue);
      expect(
        TerminalLauncher.forCurrentPlatform(),
        isA<MacOsGhosttyTerminalLauncher>(),
      );
    });
  });

  test('an unsupported platform resolves nothing and says why', () async {
    const UnsupportedTerminalLauncher launcher = UnsupportedTerminalLauncher();

    expect(await launcher.resolve(), isNull);
    expect(launcher.missingTerminalMessage, contains('macOS and Linux'));
  });
}
