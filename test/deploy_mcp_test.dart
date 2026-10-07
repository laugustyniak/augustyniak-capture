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
  }) {
    return Process.run(
      'bash',
      <String>['${repo.path}/tool/deploy-mcp.sh', cli, ...args],
      environment: <String, String>{
        'PATH': '${temp.path}/fakebin:${Platform.environment['PATH']}',
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

  test('deploy.sh calls the helper on the desktop path only, as a warning', () {
    final String script = File('tool/deploy.sh').readAsStringSync();

    // A guarded call: failure prints a warning and never aborts.
    expect(script, contains('tool/deploy-mcp.sh "\${args[@]}"'));
    expect(
      RegExp(
        r'deploy-mcp\.sh[^\n]*\\\n\s*\|\| echo "deploy: WARNING[^"]*MCP',
      ).hasMatch(script),
      isTrue,
      reason: 'the helper call must be guarded with || and a WARNING line',
    );

    // Called from the two desktop installers, and not from the android one.
    String body(String name, String next) {
      final int start = script.indexOf('$name() {');
      return script.substring(start, script.indexOf('$next() {', start));
    }

    expect(body('install_linux', 'install_macos'), contains('install_mcp'));
    expect(body('install_macos', 'install_android'), contains('install_mcp'));
    expect(
      script.substring(script.indexOf('install_android() {')),
      isNot(contains('install_mcp')),
    );
  });
}
