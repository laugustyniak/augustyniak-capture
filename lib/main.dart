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
    await hotKeyManager.unregisterAll();
  }

  runApp(const VoiceNotesApp());
}
