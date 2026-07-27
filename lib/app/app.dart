import 'package:flutter/material.dart';

import 'ui_kit.dart';

import '../features/recordings/presentation/recordings_page.dart';

class VoiceNotesApp extends StatelessWidget {
  const VoiceNotesApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Audivoa Core',
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
        fontFamily: 'Roboto',
        cardTheme: const CardThemeData(
          color: Console.surface,
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(18)),
            side: BorderSide(color: Console.border),
          ),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Console.background,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
        ),
        navigationBarTheme: const NavigationBarThemeData(
          backgroundColor: Console.surfaceDeep,
          indicatorColor: Console.navIndicator,
          labelTextStyle: WidgetStatePropertyAll(
            TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
          ),
        ),
      ),
      home: const RecordingsPage(),
    );
  }
}
