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
    'inbox.md ',
    '.env/foo',
    'dir/.agent-tasks/x',
    'notatki/Café/Inbox.md',
    '.agent-tasks/.env.example',
    '.env/.env.example',
  ];
  const List<String> allowed = <String>[
    '.env.example',
    'android/key.properties.example',
    'inbox.md.bak',
    'lib/main.dart',
    'docs/inbox-design.md',
    '.environment/x',
    'a/.env.example',
    'key.properties.bak',
    '.envrc',
    '.env.example',
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
        expect(r.stdout, '$path\n');
      });
    }

    for (final String path in allowed) {
      test('passes $path', () async {
        final ProcessResult r = await filter('$path\n');
        expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
        expect(r.stdout, isEmpty);
      });
    }

    test('a path with invalid UTF-8 is still judged, not skipped', () async {
      final Process p = await Process.start('bash', <String>[
        'tool/blocked-paths.sh',
      ]);
      // `caf\xe9/inbox.md` in Latin-1: raw bytes, which a Dart string cannot hold.
      p.stdin.add(<int>[...'caf'.codeUnits, 0xe9, ...'/inbox.md\n'.codeUnits]);
      await p.stdin.close();
      final Future<List<int>> out = p.stdout
          .expand((List<int> c) => c)
          .toList();
      final String err = await p.stderr
          .transform(const SystemEncoding().decoder)
          .join();
      final int code = await p.exitCode;
      expect(code, 1, reason: err);
      expect(await out, <int>[
        ...'caf'.codeUnits,
        0xe9,
        ...'/inbox.md\n'.codeUnits,
      ]);
      expect(err, isNot(contains('binary file')));
    });

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

    // The suite runs from the `pre-push` hook, where git exports `GIT_DIR` and
    // friends. Left in the environment they would point these commands at the
    // real repository, and the `git add -f Inbox.md` below would stage it there.
    final Map<String, String> cleanEnv =
        <String, String>{...Platform.environment}..removeWhere(
          (String k, _) => const <String>[
            'GIT_DIR',
            'GIT_WORK_TREE',
            'GIT_INDEX_FILE',
            'GIT_OBJECT_DIRECTORY',
            'GIT_PREFIX',
          ].contains(k),
        );

    ProcessResult git(List<String> args) => Process.runSync(
      'git',
      <String>['-c', 'user.email=t@example.com', '-c', 'user.name=t', ...args],
      workingDirectory: repo.path,
      environment: cleanEnv,
      includeParentEnvironment: false,
    );

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

    ProcessResult commitFile(String path) {
      final File f = File('${repo.path}/$path')..createSync(recursive: true);
      f.writeAsStringSync('x\n');
      git(<String>['add', '-f', path]);
      return git(<String>['commit', '-m', 'x']);
    }

    test('refuses a case-variant of a captured file', () {
      final ProcessResult r = commitFile('Inbox.md');
      expect(r.exitCode, isNot(0));
      expect(
        r.stderr,
        contains('refusing to commit captured content or a credential file'),
      );
    });

    test('refuses a keystore properties file in any letter case', () {
      final ProcessResult r = commitFile('android/Key.properties');
      expect(r.exitCode, isNot(0));
      expect(r.stderr, contains('refusing to commit'));
    });

    test('lets an ordinary file through', () {
      final ProcessResult r = commitFile('lib/ok.dart');
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    });

    test('lets the committed env template through', () {
      final ProcessResult r = commitFile('.env.example');
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    });

    test('refuses to commit blind when the path rule itself fails', () {
      File('${repo.path}/tool/blocked-paths.sh').writeAsStringSync('exit 3\n');
      final ProcessResult r = commitFile('lib/ok.dart');
      expect(r.exitCode, isNot(0));
      expect(r.stderr, contains('refusing to commit blind'));
    });

    test('refuses to commit blind when the path rule is missing', () {
      File('${repo.path}/tool/blocked-paths.sh').deleteSync();
      final ProcessResult r = commitFile('lib/ok.dart');
      expect(r.exitCode, isNot(0));
      expect(r.stderr, contains('refusing to commit blind'));
    });
  }, skip: skip);
}
