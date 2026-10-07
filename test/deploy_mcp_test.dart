import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `tool/deploy-mcp.sh` against a fake `dart`, so the install, the atomic swap
/// and the failure paths can be checked without a real `dart build cli` (#271).
///
/// The helper is copied into a temp copy of the repo layout and run there with
/// a temp `HOME`, so it never writes `build/mcp` into the working tree and
/// never touches the real `~/.local`.
void main() {
  const String cli = 'some-cli';
  late Directory temp;
  late Directory repo;
  late Directory home;
  late File dartLog;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('deploy_mcp_');
    repo = Directory('${temp.path}/repo')..createSync();
    home = Directory('${temp.path}/home')..createSync();
    Directory('${repo.path}/tool').createSync();
    Directory('${repo.path}/bin').createSync();
    File('tool/deploy-mcp.sh').copySync('${repo.path}/tool/deploy-mcp.sh');
    File('${repo.path}/bin/capture_mcp.dart').writeAsStringSync('// stub');
    dartLog = File('${temp.path}/dart.log');

    final Directory fakeBin = Directory('${temp.path}/fakebin')..createSync();
    final File dart = File('${fakeBin.path}/dart')
      ..writeAsStringSync(r'''#!/usr/bin/env bash
echo "$*" >> "$DART_LOG"
[ "${FAKE_DART_FAIL:-}" = 1 ] && { echo "build exploded" >&2; exit 1; }
out=""
while [ $# -gt 0 ]; do
  [ "$1" = -o ] && out="$2"
  shift
done
rm -rf "$out/bundle"
mkdir -p "$out/bundle/bin" "$out/bundle/lib"
printf '#!/bin/sh\n' > "$out/bundle/bin/capture_mcp"
chmod +x "$out/bundle/bin/capture_mcp"
if [ "${FAKE_DART_NOLIB:-}" != 1 ]; then
  case "$(uname -s)" in
    Darwin) touch "$out/bundle/lib/libsqlite3.dylib" ;;
    *) touch "$out/bundle/lib/libsqlite3.so" ;;
  esac
fi
echo "${FAKE_DART_MARKER:-}" > "$out/bundle/marker"
''');
    Process.runSync('chmod', <String>['+x', dart.path]);
  });

  tearDown(() => temp.deleteSync(recursive: true));

  Future<ProcessResult> run(
    List<String> args, {
    Map<String, String> env = const <String, String>{},
    String name = cli,
    String? path,
  }) {
    return Process.run(
      'bash',
      <String>['${repo.path}/tool/deploy-mcp.sh', name, ...args],
      environment: <String, String>{
        'PATH': path ?? '${temp.path}/fakebin:${Platform.environment['PATH']}',
        'HOME': home.path,
        'DART_LOG': dartLog.path,
        ...env,
      },
    );
  }

  String output(ProcessResult r) => '${r.stdout}${r.stderr}';
  String dest() => '${home.path}/.local/opt/$cli-mcp';
  String link() => '${home.path}/.local/bin/$cli-mcp';

  test(
    'a fresh install lands the bundle, the symlink and the registration',
    () async {
      final ProcessResult r = await run(<String>[]);

      expect(r.exitCode, 0, reason: output(r));
      expect(File('${dest()}/bin/capture_mcp').existsSync(), isTrue);
      expect(Link(link()).targetSync(), '${dest()}/bin/capture_mcp');
      expect(output(r), contains('claude mcp add $cli -- ${link()}'));
      expect(output(r), contains('[mcp_servers.$cli]'));
      expect(output(r), contains('command = "${link()}"'));
    },
  );

  test(
    'a redeploy replaces the bundle whole and leaves no .new or .old',
    () async {
      await run(<String>[], env: <String, String>{'FAKE_DART_MARKER': 'v1'});
      File('${dest()}/stale-from-v1').writeAsStringSync('x');

      final ProcessResult r = await run(
        <String>[],
        env: <String, String>{'FAKE_DART_MARKER': 'v2'},
      );

      expect(r.exitCode, 0, reason: output(r));
      expect(File('${dest()}/stale-from-v1').existsSync(), isFalse);
      expect(File('${dest()}/marker').readAsStringSync().trim(), 'v2');
      expect(Directory('${dest()}.new').existsSync(), isFalse);
      expect(Directory('${dest()}.old').existsSync(), isFalse);
    },
  );

  test(
    'a build failure exits non-zero and keeps the previous install',
    () async {
      await run(<String>[], env: <String, String>{'FAKE_DART_MARKER': 'v1'});

      final ProcessResult r = await run(
        <String>[],
        env: <String, String>{'FAKE_DART_FAIL': '1', 'FAKE_DART_MARKER': 'v2'},
      );

      expect(r.exitCode, isNot(0));
      expect(r.stderr, contains('deploy-mcp: dart build cli failed'));
      expect(File('${dest()}/marker').readAsStringSync().trim(), 'v1');
      expect(Directory('${dest()}.new').existsSync(), isFalse);
    },
  );

  test(
    '--skip-build installs the existing bundle without running dart',
    () async {
      await run(<String>[], env: <String, String>{'FAKE_DART_MARKER': 'built'});
      Directory(dest()).deleteSync(recursive: true);
      dartLog.deleteSync();

      final ProcessResult r = await run(<String>['--skip-build']);

      expect(r.exitCode, 0, reason: output(r));
      expect(dartLog.existsSync(), isFalse, reason: 'dart must not be invoked');
      expect(File('${dest()}/marker').readAsStringSync().trim(), 'built');
    },
  );

  test('--skip-build with no bundle fails with a clear message', () async {
    final ProcessResult r = await run(<String>['--skip-build']);

    expect(r.exitCode, isNot(0));
    expect(r.stderr, contains('no built MCP bundle'));
    expect(r.stderr, contains('drop --skip-build'));
    expect(Directory(dest()).existsSync(), isFalse);
  });

  test(
    'a bundle without libsqlite3 is refused and the old install stays',
    () async {
      await run(<String>[], env: <String, String>{'FAKE_DART_MARKER': 'v1'});

      final ProcessResult r = await run(
        <String>[],
        env: <String, String>{'FAKE_DART_NOLIB': '1', 'FAKE_DART_MARKER': 'v2'},
      );

      expect(r.exitCode, isNot(0));
      expect(r.stderr, contains('libsqlite3'));
      expect(File('${dest()}/marker').readAsStringSync().trim(), 'v1');
    },
  );

  test(
    'only .old left by a crashed swap is recovered when the build fails',
    () async {
      await run(<String>[], env: <String, String>{'FAKE_DART_MARKER': 'v1'});
      Directory(dest()).renameSync('${dest()}.old');

      final ProcessResult r = await run(
        <String>[],
        env: <String, String>{'FAKE_DART_FAIL': '1'},
      );

      expect(r.exitCode, isNot(0));
      expect(File('${dest()}/marker').readAsStringSync().trim(), 'v1');
      expect(Directory('${dest()}.old').existsSync(), isFalse);
    },
  );

  test(
    'a stale .new from a crashed run is cleaned up and the install succeeds',
    () async {
      Directory('${dest()}.new').createSync(recursive: true);
      File('${dest()}.new/junk').writeAsStringSync('x');

      final ProcessResult r = await run(<String>[]);

      expect(r.exitCode, 0, reason: output(r));
      expect(File('${dest()}/bin/capture_mcp').existsSync(), isTrue);
      expect(File('${dest()}/junk').existsSync(), isFalse);
      expect(Directory('${dest()}.new').existsSync(), isFalse);
    },
  );

  test(
    'a stale .old beside a live install does not swallow the next swap',
    () async {
      await run(<String>[], env: <String, String>{'FAKE_DART_MARKER': 'v1'});
      File('${dest()}.old/$cli-mcp/x').createSync(recursive: true);

      final ProcessResult r = await run(
        <String>[],
        env: <String, String>{'FAKE_DART_MARKER': 'v2'},
      );

      expect(r.exitCode, 0, reason: output(r));
      expect(File('${dest()}/marker').readAsStringSync().trim(), 'v2');
      expect(Directory('${dest()}.old').existsSync(), isFalse);
    },
  );

  for (final String kind in <String>['directory', 'file']) {
    test(
      'a $kind where the symlink belongs is refused, not replaced',
      () async {
        await run(<String>[], env: <String, String>{'FAKE_DART_MARKER': 'v1'});
        Link(link()).deleteSync();
        if (kind == 'directory') {
          Directory(link()).createSync();
        } else {
          File(link()).writeAsStringSync('mine');
        }

        final ProcessResult r = await run(
          <String>[],
          env: <String, String>{'FAKE_DART_MARKER': 'v2'},
        );

        expect(r.exitCode, isNot(0));
        expect(r.stderr, contains(link()));
        expect(r.stderr, contains('not a symlink'));
        expect(File('${dest()}/marker').readAsStringSync().trim(), 'v1');
        expect(
          FileSystemEntity.isLinkSync(link()),
          isFalse,
          reason: 'the user\'s $kind must be left alone',
        );
      },
    );
  }

  for (final String bad in <String>['', '../x', 'a/b', 'x..y']) {
    test('cli name "$bad" is refused before anything is touched', () async {
      final Directory canary = Directory('${home.path}/.local/opt/canary')
        ..createSync(recursive: true);

      final ProcessResult r = await run(<String>[], name: bad);

      expect(r.exitCode, isNot(0));
      expect(r.stderr, contains('deploy-mcp:'));
      expect(canary.existsSync(), isTrue);
      expect(dartLog.existsSync(), isFalse, reason: 'dart must not run');
      expect(Directory('${home.path}/x-mcp').existsSync(), isFalse);
      expect(Directory('${home.path}/.local/x-mcp').existsSync(), isFalse);
    });
  }

  test('a missing dart is reported by name', () async {
    final ProcessResult r = await run(<String>[], path: '/usr/bin:/bin');

    expect(r.exitCode, isNot(0));
    expect(r.stderr, contains('dart'));
    expect(r.stderr, contains('deploy-mcp: dart not found'));
    expect(Directory(dest()).existsSync(), isFalse);
  });

  group('deploy.sh wiring', () {
    // deploy.sh run for real in a temp copy of the layout it reads, with
    // `--skip-build` and a placeholder bundle, so no build happens and the
    // install lands under the temp HOME. The MCP helper is a stub.
    late Directory fake;

    Future<ProcessResult> deploy(
      List<String> args, {
      required int helperExit,
    }) async {
      fake = Directory('${temp.path}/deployrepo')..createSync();
      Directory('${fake.path}/tool').createSync();
      Directory('${fake.path}/linux').createSync();
      Directory(
        '${fake.path}/macos/Runner/Configs',
      ).createSync(recursive: true);
      Directory(
        '${fake.path}/build/linux/x64/release/bundle',
      ).createSync(recursive: true);
      File('tool/deploy.sh').copySync('${fake.path}/tool/deploy.sh');
      File('${fake.path}/linux/CMakeLists.txt').writeAsStringSync(
        'set(BINARY_NAME "some_cli")\nset(APPLICATION_ID "x.y.z")\n',
      );
      File(
        '${fake.path}/macos/Runner/Configs/AppInfo.xcconfig',
      ).writeAsStringSync('PRODUCT_NAME = Some Cli\n');
      File('${fake.path}/pubspec.yaml').writeAsStringSync('description: d\n');
      File('${fake.path}/build/linux/x64/release/bundle/some_cli')
        ..writeAsStringSync('#!/bin/sh\n')
        ..createSync();
      File('${fake.path}/stub.log');
      File('${fake.path}/tool/deploy-mcp.sh').writeAsStringSync(
        '#!/usr/bin/env bash\necho "\$*" >> "${fake.path}/stub.log"\n'
        'exit $helperExit\n',
      );
      // The desktop-integration tools are stubbed: the fixture's launcher is
      // not meant to validate, and this test is about the MCP call only.
      for (final String tool in <String>[
        'desktop-file-validate',
        'update-desktop-database',
        'gtk-update-icon-cache',
      ]) {
        File('${temp.path}/fakebin/$tool')
          ..writeAsStringSync('#!/bin/sh\nexit 0\n')
          ..createSync();
        Process.runSync('chmod', <String>['+x', '${temp.path}/fakebin/$tool']);
      }
      Process.runSync('chmod', <String>[
        '+x',
        '${fake.path}/tool/deploy.sh',
        '${fake.path}/tool/deploy-mcp.sh',
        '${fake.path}/build/linux/x64/release/bundle/some_cli',
      ]);
      for (final List<String> git in <List<String>>[
        <String>['init', '-q'],
        <String>['add', '-A'],
        <String>[
          '-c',
          'user.name=t',
          '-c',
          'user.email=t@t',
          'commit',
          '-q',
          '-m',
          'x',
        ],
      ]) {
        Process.runSync('git', git, workingDirectory: fake.path);
      }
      return Process.run(
        'bash',
        <String>['${fake.path}/tool/deploy.sh', ...args],
        environment: <String, String>{
          'PATH': '${temp.path}/fakebin:${Platform.environment['PATH']}',
          'HOME': home.path,
          'XDG_CONFIG_HOME': home.path,
          'XDG_DATA_HOME': '${home.path}/data',
        },
      );
    }

    final bool linux = Platform.isLinux;

    test(
      'a failing helper is a warning and the deploy still succeeds',
      () async {
        final ProcessResult r = await deploy(<String>[
          '--skip-build',
        ], helperExit: 1);

        expect(r.exitCode, 0, reason: output(r));
        expect(r.stderr, contains('WARNING'));
        expect(r.stderr, contains('MCP'));
        expect(
          File('${fake.path}/stub.log').readAsStringSync().trim(),
          'some-cli --skip-build',
        );
      },
      skip: linux ? false : 'the host install branch is Linux-specific',
    );

    test(
      'a working helper gets the cli name and no warning',
      () async {
        final ProcessResult r = await deploy(<String>[
          '--skip-build',
        ], helperExit: 0);

        expect(r.exitCode, 0, reason: output(r));
        expect(r.stderr, isNot(contains('MCP')));
      },
      skip: linux ? false : 'the host install branch is Linux-specific',
    );

    test('--android never calls the helper', () async {
      // A fake adb with no attached device ends the android path with 3.
      File('${temp.path}/fakebin/adb')
        ..writeAsStringSync(
          '#!/usr/bin/env bash\necho "List of devices attached"\n',
        )
        ..createSync();
      Process.runSync('chmod', <String>['+x', '${temp.path}/fakebin/adb']);

      final ProcessResult r = await deploy(<String>[
        '--android',
        '--skip-build',
      ], helperExit: 0);

      expect(r.exitCode, 3, reason: output(r));
      expect(File('${fake.path}/stub.log').existsSync(), isFalse);
    });
  });
}
