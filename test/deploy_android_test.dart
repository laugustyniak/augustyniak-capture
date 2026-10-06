import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `tool/deploy.sh --android` against a fake `adb`, so the device loop's exit
/// codes and messages can be checked without a phone (#243).
///
/// The script is run with `--skip-build` and a placeholder APK, and with `HOME`
/// and `XDG_CONFIG_HOME` pointed at a temp directory, so it never builds and
/// never reads a real defines file.
void main() {
  const String apk = 'build/app/outputs/flutter-apk/app-release.apk';
  late Directory temp;
  late bool createdApk;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('deploy_android_');
    final File placeholder = File(apk);
    createdApk = !placeholder.existsSync();
    if (createdApk) {
      placeholder
        ..createSync(recursive: true)
        ..writeAsStringSync('placeholder');
    }
  });

  tearDown(() {
    temp.deleteSync(recursive: true);
    if (createdApk) File(apk).deleteSync();
  });

  /// [devices] maps a serial to how the fake treats it: `ok` answers and
  /// installs, `ghost` fails every command (a stale second transport), and
  /// `incompatible` answers but refuses the install with a signature mismatch.
  Future<ProcessResult> deploy(Map<String, String> devices) async {
    final Directory bin = Directory('${temp.path}/bin')..createSync();
    final String cases = devices.entries
        .map((MapEntry<String, String> e) => '  ${e.key}) echo ${e.value} ;;')
        .join('\n');
    final File adb = File('${bin.path}/adb')
      ..writeAsStringSync('''#!/usr/bin/env bash
mode_of() {
  case "\$1" in
$cases
    *) echo missing ;;
  esac
}
if [ "\$1" = devices ]; then
  echo "List of devices attached"
${devices.keys.map((String s) => '  printf "%s\\tdevice\\n" $s').join('\n')}
  exit 0
fi
[ "\$1" = -s ] || exit 1
mode="\$(mode_of "\$2")"
shift 2
[ "\$mode" = ghost ] && { echo "error: device offline" >&2; exit 1; }
case "\$1" in
  shell) echo "Pixel Fake"; exit 0 ;;
  install)
    if [ "\$mode" = incompatible ]; then
      echo "Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: signatures do not match]"
      exit 1
    fi
    echo Success; exit 0 ;;
esac
exit 1
''');
    await Process.run('chmod', <String>['+x', adb.path]);
    return Process.run(
      'bash',
      <String>['tool/deploy.sh', '--android', '--skip-build'],
      environment: <String, String>{
        'PATH': '${bin.path}:${Platform.environment['PATH']}',
        'HOME': temp.path,
        'XDG_CONFIG_HOME': temp.path,
        'ANDROID_HOME': '',
        'ANDROID_SDK_ROOT': '',
      },
    );
  }

  String output(ProcessResult r) => '${r.stdout}${r.stderr}';

  test(
    'an unreachable second transport is skipped, not an install failure',
    () async {
      final ProcessResult result = await deploy(<String, String>{
        'ghost-serial': 'ghost',
        'good-serial': 'ok',
      });

      expect(output(result), contains('installed on Pixel Fake'));
      expect(output(result), contains('ghost-serial not reachable — skipped'));
      expect(output(result), isNot(contains('uninstall')));
      expect(result.exitCode, 0, reason: output(result));
    },
  );

  test('no reachable device at all is the no-device exit, 3', () async {
    final ProcessResult result = await deploy(<String, String>{
      'ghost-serial': 'ghost',
    });

    expect(output(result), contains('ghost-serial not reachable — skipped'));
    expect(result.exitCode, 3, reason: output(result));
  });

  test('a signature mismatch fails, and never says to uninstall', () async {
    final ProcessResult result = await deploy(<String, String>{
      'old-serial': 'incompatible',
    });

    expect(result.exitCode, 1, reason: output(result));
    expect(output(result), contains('NOT uninstalling'));
  });
}
