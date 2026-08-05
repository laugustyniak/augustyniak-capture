import 'dart:io';

import 'process_runner.dart';

/// Turns a command name into an absolute path.
///
/// **This exists because a bundled macOS app does not inherit the user's
/// `PATH`.** Launched from Finder or `/Applications`, the process environment
/// carries `/usr/bin:/bin:/usr/sbin:/sbin` and nothing else — so `zellij`
/// (Homebrew) and every agent CLI (`~/.local/bin`, Cargo, Bun, Volta) are
/// simply absent. The app then fails in the one shape that is hardest to read:
/// `Process.run('zellij', …)` throws before anything opens, and a `command=`
/// in a Zellij layout produces a window that closes again immediately. Neither
/// mentions `PATH`. Running the launcher from `flutter run` masks it entirely,
/// because a terminal-started process *does* inherit the login shell's `PATH`.
///
/// Resolution is deliberately ordered cheapest-first and only ever answers with
/// a path that exists on disk:
///
/// 1. the process `PATH` — correct and free when the app was started from a
///    terminal, and the only entry that honours a deliberately shadowed binary;
/// 2. the conventional install directories, which cover Homebrew, Cargo, Bun,
///    Volta and a plain `~/.local/bin` without spawning anything;
/// 3. the login shell, asked once, for version managers (mise, asdf, nvm) whose
///    directories cannot be guessed. It is the slowest step and the last.
abstract interface class ExecutableResolver {
  /// Absolute path of [name], or null when it cannot be found.
  Future<String?> resolve(String name);
}

class PathExecutableResolver implements ExecutableResolver {
  PathExecutableResolver({
    ProcessRunner processRunner = const SystemProcessRunner(),
    Map<String, String>? environment,
    List<String>? conventionalDirectories,
  }) : _processRunner = processRunner,
       _environment = environment ?? Platform.environment,
       _conventional = conventionalDirectories;

  final ProcessRunner _processRunner;
  final Map<String, String> _environment;

  /// Injectable because the defaults are absolute machine paths. Left implicit,
  /// `/opt/homebrew/bin` exists on the developer's machine and not on a build
  /// agent, so a test asserting the *later* steps would silently stop reaching
  /// them — it would pass by finding the real Homebrew binary instead.
  final List<String>? _conventional;

  /// Resolution is a property of the installation, not of the launch, so it is
  /// cached for the session. A `null` is cached too: a missing binary is
  /// reported to the user as such, and retrying the login shell on every tap
  /// would put a shell start-up on the path of a control that already failed.
  final Map<String, String?> _cache = <String, String?>{};

  @override
  Future<String?> resolve(String name) async {
    if (_cache.containsKey(name)) return _cache[name];
    final String? resolved =
        _firstIn(_pathDirectories(), name) ??
        _firstIn(_conventionalDirectories(), name) ??
        await _askLoginShell(name);
    _cache[name] = resolved;
    return resolved;
  }

  static String? _firstIn(Iterable<String> directories, String name) {
    for (final String directory in directories) {
      final String candidate = '$directory/$name';
      if (_isExecutable(candidate)) return candidate;
    }
    return null;
  }

  Iterable<String> _pathDirectories() =>
      (_environment['PATH'] ?? '').split(':').where((String d) => d.isNotEmpty);

  Iterable<String> _conventionalDirectories() {
    final List<String>? overridden = _conventional;
    if (overridden != null) return overridden;
    final String home = _environment['HOME'] ?? '';
    return <String>[
      '/opt/homebrew/bin',
      '/usr/local/bin',
      if (home.isNotEmpty) ...<String>[
        '$home/.local/bin',
        '$home/bin',
        '$home/.cargo/bin',
        '$home/.bun/bin',
        '$home/.volta/bin',
        '$home/.npm-global/bin',
      ],
    ];
  }

  /// Asks the user's login shell where the binary is, without ever building a
  /// command string out of [name]: it arrives as `$0`, so a name is data to the
  /// shell rather than something it could parse.
  Future<String?> _askLoginShell(String name) async {
    final String shell = _environment['SHELL'] ?? '/bin/zsh';
    try {
      final CommandResult result = await _processRunner.run(shell, <String>[
        '-lc',
        'command -v "\$0"',
        name,
      ]);
      if (result.exitCode != 0) return null;
      // A login shell prints whatever the user's rc files print, so the answer
      // is the last absolute path it emitted rather than the whole of stdout.
      for (final String line in result.stdout.split('\n').reversed) {
        final String candidate = line.trim();
        if (candidate.startsWith('/') && _isExecutable(candidate)) {
          return candidate;
        }
      }
    } on ProcessException {
      return null;
    } on FileSystemException {
      return null;
    }
    return null;
  }

  static bool _isExecutable(String path) => File(path).existsSync();
}
