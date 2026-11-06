import 'dart:io';

import '../domain/outcome_review.dart';

/// Runs one process and answers its exit code. Throws when the executable
/// cannot be started at all — `Process.run`'s own behaviour, kept so a missing
/// binary is reported rather than read as success.
typedef OutcomeProcessRunner =
    Future<int> Function(
      String executable,
      List<String> arguments, {
      Map<String, String>? environment,
    });

Future<int> _runProcess(
  String executable,
  List<String> arguments, {
  Map<String, String>? environment,
}) async {
  // No shell: every piece of text below is an argument or an environment
  // variable, never part of a command line something could parse.
  final ProcessResult result = await Process.run(
    executable,
    arguments,
    environment: environment,
    runInShell: false,
  );
  return result.exitCode;
}

bool _isFile(String path) => File(path).existsSync();

/// The app's name as the desktop notification shows it.
const String outcomeNotificationAppName = 'Augustyniak Capture';

/// Environment variable the Windows speaker passes its text through, so the
/// summary is never spliced into the PowerShell command itself.
const String outcomeSpeechVariable = 'CAPTURE_OUTCOME_SPEECH';

/// Directories searched for a Linux binary, after the process `PATH`. A
/// desktop launcher's `PATH` can be short, and both tools live in `/usr/bin`
/// on every distribution that ships them.
const List<String> _linuxFallbackDirectories = <String>[
  '/usr/bin',
  '/usr/local/bin',
  '/bin',
];

String? _findOnLinux(
  List<String> names,
  Map<String, String> environment,
  bool Function(String path) exists,
) {
  final List<String> directories = <String>[
    ...(environment['PATH'] ?? '').split(':').where((String d) => d.isNotEmpty),
    ..._linuxFallbackDirectories,
  ];
  for (final String name in names) {
    for (final String directory in directories) {
      final String candidate = '$directory/$name';
      if (exists(candidate)) return candidate;
    }
  }
  return null;
}

String? _windowsPowerShell(
  Map<String, String> environment,
  bool Function(String path) exists,
) {
  final String root =
      environment['SystemRoot'] ?? environment['SYSTEMROOT'] ?? r'C:\Windows';
  final String candidate =
      '$root\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
  return exists(candidate) ? candidate : null;
}

/// Reads an outcome summary aloud with the desktop's own speech engine.
///
/// On-device on every platform it supports, which is the point: the summary is
/// already free of capture text, and it still never leaves the machine.
///
/// - macOS: `/usr/bin/say`, present on every install.
/// - Linux: `spd-say -w` (speech-dispatcher), else `espeak-ng`, else `espeak`.
///   None is guaranteed, so availability is the binary being found.
/// - Windows: `System.Speech` through the inbox PowerShell, the text passed in
///   an environment variable.
/// - Android and iOS: unavailable until a TTS plugin is added; the Listen
///   control is then simply not offered and the card stays the whole feature.
class SystemOutcomeSpeaker implements OutcomeSpeaker {
  SystemOutcomeSpeaker({
    String? operatingSystem,
    Map<String, String>? environment,
    OutcomeProcessRunner runProcess = _runProcess,
    bool Function(String path) exists = _isFile,
  }) : _os = operatingSystem ?? Platform.operatingSystem,
       _environment = environment ?? Platform.environment,
       _run = runProcess,
       _exists = exists;

  final String _os;
  final Map<String, String> _environment;
  final OutcomeProcessRunner _run;
  final bool Function(String path) _exists;

  /// The command that speaks [text], or null when this host has no engine.
  /// Asked afresh on every call: a user who installs `espeak` mid-session
  /// should get the control on the next probe, and the lookup is a handful of
  /// `stat`s.
  ({String executable, List<String> arguments, Map<String, String>? env})?
  _commandFor(String text) {
    switch (_os) {
      case 'macos':
        const String say = '/usr/bin/say';
        if (!_exists(say)) return null;
        return (executable: say, arguments: <String>[text], env: null);
      case 'linux':
        final String? binary = _findOnLinux(
          const <String>['spd-say', 'espeak-ng', 'espeak'],
          _environment,
          _exists,
        );
        if (binary == null) return null;
        // `spd-say` returns as soon as the text is queued; `-w` makes it wait
        // so a failure is reported by this call rather than lost.
        final bool spd = binary.endsWith('/spd-say');
        return (
          executable: binary,
          arguments: <String>[if (spd) '-w', text],
          env: null,
        );
      case 'windows':
        final String? powershell = _windowsPowerShell(_environment, _exists);
        if (powershell == null) return null;
        return (
          executable: powershell,
          arguments: <String>[
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            'Add-Type -AssemblyName System.Speech; '
                '(New-Object System.Speech.Synthesis.SpeechSynthesizer)'
                '.Speak(\$env:$outcomeSpeechVariable)',
          ],
          env: <String, String>{outcomeSpeechVariable: text},
        );
      default:
        return null;
    }
  }

  @override
  Future<bool> isAvailable() async => _commandFor('') != null;

  @override
  Future<void> speak(String text) async {
    final command = _commandFor(text);
    if (command == null) {
      throw UnsupportedError('No text-to-speech engine on this host.');
    }
    final int exitCode = await _run(
      command.executable,
      command.arguments,
      environment: command.env,
    );
    if (exitCode != 0) {
      throw ProcessException(
        command.executable,
        const <String>[],
        'Speech engine exited with $exitCode.',
        exitCode,
      );
    }
  }
}

/// Shows an outcome change as a desktop notification.
///
/// - macOS: `osascript`'s `display notification`, the title and body passed as
///   `argv` so neither is ever parsed as AppleScript.
/// - Linux: `notify-send` (libnotify), when installed.
/// - Windows, Android, iOS: answers false — a toast needs a plugin this build
///   does not carry, and the card already shows the outcome.
///
/// There is no tap or reply action on these notifications: neither tool can
/// call back into the app. Listen and Reply live on the card's outcome line and
/// on the queue's keyboard layer instead.
class SystemOutcomeNotifier implements OutcomeNotifier {
  SystemOutcomeNotifier({
    String? operatingSystem,
    Map<String, String>? environment,
    OutcomeProcessRunner runProcess = _runProcess,
    bool Function(String path) exists = _isFile,
  }) : _os = operatingSystem ?? Platform.operatingSystem,
       _environment = environment ?? Platform.environment,
       _run = runProcess,
       _exists = exists;

  final String _os;
  final Map<String, String> _environment;
  final OutcomeProcessRunner _run;
  final bool Function(String path) _exists;

  @override
  Future<bool> notify(OutcomeAnnouncement announcement) async {
    final String title = announcement.title;
    final String body = announcement.summary;
    switch (_os) {
      case 'macos':
        const String osascript = '/usr/bin/osascript';
        if (!_exists(osascript)) return false;
        return await _run(osascript, <String>[
              '-e',
              'on run argv',
              '-e',
              'display notification (item 2 of argv) '
                  'with title (item 1 of argv)',
              '-e',
              'end run',
              title,
              body,
            ]) ==
            0;
      case 'linux':
        final String? notifySend = _findOnLinux(
          const <String>['notify-send'],
          _environment,
          _exists,
        );
        if (notifySend == null) return false;
        return await _run(notifySend, <String>[
              '--app-name=$outcomeNotificationAppName',
              '--',
              title,
              body,
            ]) ==
            0;
      default:
        return false;
    }
  }
}
