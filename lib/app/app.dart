import 'package:flutter/material.dart';

import '../features/recordings/presentation/recordings_page.dart';

class VoiceNotesApp extends StatelessWidget {
  const VoiceNotesApp({super.key});

  @override
  Widget build(BuildContext context) {
    const Color cyan = Color(0xFF31D5F4);
    const Color background = Color(0xFF07111F);
    const Color surface = Color(0xFF10243A);

    return MaterialApp(
      title: 'Audivoa Core',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: background,
        colorScheme: const ColorScheme.dark(
          primary: cyan,
          secondary: cyan,
          surface: surface,
          error: Color(0xFFFF6B81),
        ),
        useMaterial3: true,
        fontFamily: 'Roboto',
        cardTheme: const CardThemeData(
          color: surface,
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(18)),
            side: BorderSide(color: Color(0xFF1B3852)),
          ),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: background,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
        ),
        navigationBarTheme: const NavigationBarThemeData(
          backgroundColor: Color(0xFF0C1D2E),
          indicatorColor: Color(0xFF173D52),
          labelTextStyle: WidgetStatePropertyAll(
            TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
          ),
        ),
      ),
      home: const RecordingsPage(),
    );
  }
}
