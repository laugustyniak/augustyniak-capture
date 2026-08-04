import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'app/app.dart';

Future<void> main() async {
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

  runApp(const AugustyniakCaptureApp());
}
