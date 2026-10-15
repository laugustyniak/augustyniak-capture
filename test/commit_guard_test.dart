import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `tool/blocked-paths.sh` and the `pre-commit` hook that delegates to it
/// (#305). The path rule is one script so the hook and the CI `guard` job
/// cannot drift apart; these tests pin what it blocks and, as importantly,
/// what it lets through.
void main() {
  const List<String> blocked = <String>[
    '.agent-tasks/x.md',
    'Inbox.md',
    '.Agent-Tasks/x.md',
    'notes/inbox.md',
    'android/Key.properties',
    'android/key.properties',
    'keys/release.jks',
    'cert.P12',
    'x.keystore',
    'server.pem',
    'ios/app.mobileprovision',
    'ios/Runner/GoogleService-Info.plist',
    'android/app/google-services.json',
    '.env',
    '.env.local',
    'tool/.env.production',
  ];
  const List<String> allowed = <String>[
    '.env.example',
    'android/key.properties.example',
    'inbox.md.bak',
    'lib/main.dart',
    'docs/inbox-design.md',
    '.environment/x',
  ];

  Future<ProcessResult> filter(String stdin) async {
    final Process p = await Process.start('bash', <String>[
      'tool/blocked-paths.sh',
    ]);
    p.stdin.write(stdin);
    await p.stdin.close();
    final Future<String> out = p.stdout
        .transform(const SystemEncoding().decoder)
        .join();
    final Future<String> err = p.stderr
        .transform(const SystemEncoding().decoder)
        .join();
    final int code = await p.exitCode;
    return ProcessResult(p.pid, code, await out, await err);
  }

  final Object skip = Platform.isWindows ? 'needs bash' : false;

  group('tool/blocked-paths.sh', () {
    for (final String path in blocked) {
      test('blocks $path', () async {
        final ProcessResult r = await filter('$path\n');
        expect(r.exitCode, 1, reason: '${r.stdout}${r.stderr}');
        expect((r.stdout as String).trim(), path);
      });
    }

    for (final String path in allowed) {
      test('passes $path', () async {
        final ProcessResult r = await filter('$path\n');
        expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
        expect(r.stdout, isEmpty);
      });
    }

    test('a mixed list prints only the blocked paths', () async {
      final ProcessResult r = await filter(
        'lib/main.dart\nInbox.md\n.env.example\nkeys/release.jks\n',
      );
      expect(r.exitCode, 1);
      expect((r.stdout as String).trim().split('\n'), <String>[
        'Inbox.md',
        'keys/release.jks',
      ]);
    });

    test('the tracked tree holds none of them', () async {
      final ProcessResult ls = await Process.run('git', <String>[
        'ls-files',
        '-z',
      ], stdoutEncoding: null);
      final String paths = String.fromCharCodes(
        ls.stdout as List<int>,
      ).replaceAll('\u0000', '\n');
      final ProcessResult r = await filter(paths);
      expect(r.exitCode, 0, reason: '${r.stdout}');
    });
  }, skip: skip);

  group('pre-commit hook', () {
    late Directory repo;

    ProcessResult git(List<String> args) => Process.runSync('git', <String>[
      '-c',
      'user.email=t@example.com',
      '-c',
      'user.name=t',
      ...args,
    ], workingDirectory: repo.path);

    setUp(() {
      repo = Directory.systemTemp.createTempSync('commit_guard_');
      Directory('${repo.path}/.githooks').createSync();
      Directory('${repo.path}/tool').createSync();
      File(
        '.githooks/pre-commit',
      ).copySync('${repo.path}/.githooks/pre-commit');
      File(
        'tool/blocked-paths.sh',
      ).copySync('${repo.path}/tool/blocked-paths.sh');
      for (final String f in <String>[
        '.githooks/pre-commit',
        'tool/blocked-paths.sh',
      ]) {
        Process.runSync('chmod', <String>['+x', '${repo.path}/$f']);
      }
      git(<String>['init', '-q']);
      git(<String>['config', 'core.hooksPath', '.githooks']);
    });

    tearDown(() => repo.deleteSync(recursive: true));

    test('refuses a case-variant of a captured file', () {
      File('${repo.path}/Inbox.md').writeAsStringSync('notes');
      git(<String>['add', '-f', 'Inbox.md']);
      final ProcessResult r = git(<String>['commit', '-m', 'x']);
      expect(r.exitCode, isNot(0));
      expect(r.stderr, contains('refusing to commit captured content'));
    });

    test('lets an ordinary file through', () {
      Directory('${repo.path}/lib').createSync();
      File('${repo.path}/lib/ok.dart').writeAsStringSync('void main() {}\n');
      git(<String>['add', 'lib/ok.dart']);
      final ProcessResult r = git(<String>['commit', '-m', 'x']);
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    });
  }, skip: skip);
}
