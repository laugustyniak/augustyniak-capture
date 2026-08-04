import 'package:flutter/material.dart';

import 'ui_kit.dart';

import '../features/recordings/presentation/recordings_page.dart';

class AugustyniakCaptureApp extends StatelessWidget {
  const AugustyniakCaptureApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Augustyniak Capture',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Console.background,
        colorScheme: const ColorScheme.dark(
          primary: Console.cyan,
          secondary: Console.cyan,
          surface: Console.surface,
          error: Console.red,
        ),
        useMaterial3: true,
        // Space Grotesk is the default face; anything factual opts into
        // JetBrains Mono explicitly through `ConsoleText`.
        fontFamily: ConsoleFont.display,
        textTheme: const TextTheme().apply(
          bodyColor: Console.text,
          displayColor: Console.text,
        ),
        cardTheme: const CardThemeData(
          color: Console.surface,
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
            side: BorderSide(color: Console.border),
          ),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Console.background,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
        ),
        dialogTheme: const DialogThemeData(backgroundColor: Console.surface),
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: Console.background,
          surfaceTintColor: Colors.transparent,
        ),
      ),
      home: const RecordingsPage(),
    );
  }
}
