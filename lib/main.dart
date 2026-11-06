import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:window_manager/window_manager.dart';

import 'app/app.dart';
import 'features/auth/data/secure_auth_storage.dart';
import 'features/auth/domain/supabase_config.dart';
import 'features/shortcuts/data/app_links_shortcut_link_source.dart';
import 'features/shortcuts/domain/shortcut_link_source.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    // Needed before anything can show/restore/focus the window from a hotkey.
    await windowManager.ensureInitialized();
    // A hot restart leaves the previous run's hotkeys registered with the OS,
    // where they would fire into a dead isolate. Clearing on startup is the
    // documented fix and is harmless on a cold start.
    //
    // Linux is deliberately excluded. `LinuxHotkeyRegistrar` owns that platform
    // channel outright, and touching `hotKeyManager` here would construct its
    // singleton — which subscribes to the shared event channel and would fight
    // the registrar's own listener for it. The registrar clears the OS table
    // itself on its first `apply`.
    if (!Platform.isLinux) await hotKeyManager.unregisterAll();
  }

  final SupabaseConfig? supabase = SupabaseConfig.fromEnvironment();
  SupabaseClient? supabaseClient;
  if (supabase != null) {
    final SecureAuthStorage authStorage = SecureAuthStorage();
    try {
      await Supabase.initialize(
        url: supabase.url,
        publishableKey: supabase.publishableKey,
        authOptions: FlutterAuthClientOptions(
          authFlowType: AuthFlowType.pkce,
          localStorage: authStorage,
          pkceAsyncStorage: authStorage,
        ),
        debug: false,
      );
      supabaseClient = Supabase.instance.client;
    } catch (error) {
      // Authentication is optional. A bad endpoint or unavailable keyring may
      // disable cloud access, but must never prevent local capture from opening.
      debugPrint(
        'Supabase authentication is unavailable (${error.runtimeType}).',
      );
    }
  }

  if (supabase == null) {
    final String? issue = SupabaseConfig.environmentIssue();
    if (issue != null) debugPrint('Supabase is not initialised: $issue');
  }

  runApp(
    AugustyniakCaptureApp(
      supabaseClient: supabaseClient,
      // A cold start from a desktop keybinding carries its shortcut URL here;
      // the Linux runner strips it from the command line so `app_links` does
      // not deliver it a second time.
      launchArguments: args,
      // Linux only: GNOME Wayland is where the desktop has to own the key and
      // reach the app through a URL. Elsewhere the hotkey registrars work.
      shortcutLinkSource: Platform.isLinux
          ? AppLinksShortcutLinkSource()
          : const NoopShortcutLinkSource(),
    ),
  );
}
