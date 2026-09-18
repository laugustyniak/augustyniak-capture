import 'dart:io';

import 'package:augustyniak_capture/features/auth/domain/auth_redirect.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  String read(String path) => File(path).readAsStringSync();

  test('the OAuth callback is one stable non-web URI', () {
    expect(
      AuthRedirect.native.toString(),
      'ai.augustyniak.capture://login-callback/',
    );
  });

  test('Supabase allows the exact native OAuth callback', () {
    final String config = read('supabase/config.toml');
    expect(
      config,
      contains('"ai.augustyniak.capture://login-callback/"'),
    );
    expect(config, contains('[auth.external.google]'));
    expect(config, contains('enabled = true'));
    expect(
      config,
      contains('secret = "env(SUPABASE_AUTH_EXTERNAL_GOOGLE_CREDENTIAL)"'),
    );
  });

  test('Android, iOS and macOS register the OAuth callback scheme', () {
    final String android = read('android/app/src/main/AndroidManifest.xml');
    expect(android, contains('android:scheme="ai.augustyniak.capture"'));
    expect(android, contains('android:host="login-callback"'));
    expect(android, contains('flutter_deeplinking_enabled'));

    for (final String path in <String>[
      'ios/Runner/Info.plist',
      'macos/Runner/Info.plist',
    ]) {
      final String plist = read(path);
      expect(plist, contains('CFBundleURLTypes'), reason: path);
      expect(plist, contains('ai.augustyniak.capture'), reason: path);
    }
  });

  test('desktop runners forward callbacks into app_links', () {
    final String linux = read('linux/runner/my_application.cc');
    expect(linux, contains('G_APPLICATION_HANDLES_COMMAND_LINE'));
    expect(linux, contains('G_APPLICATION_HANDLES_OPEN'));

    final String deploy = read('tool/deploy.sh');
    expect(deploy, contains(r'x-scheme-handler/$application_id'));
    expect(deploy, contains(r'Exec=$opt_dir/$binary_name %u'));

    final String windows = read('windows/runner/main.cpp');
    expect(windows, contains('SendAppLinkToInstance()'));
    expect(windows, contains('ai.augustyniak.capture'));
  });
}
