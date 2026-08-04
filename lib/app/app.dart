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
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: Console.surfaceDeep,
          indicatorColor: Console.navIndicator,
          // The design's nav is a flat strip: no elevation tint, no pill
          // behind the selected icon — selection is carried by colour alone.
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          height: 66,
          labelTextStyle: WidgetStateProperty.resolveWith<TextStyle>(
            (Set<WidgetState> states) => ConsoleText.navLabel.copyWith(
              color: states.contains(WidgetState.selected)
                  ? Console.cyan
                  : Console.dimText,
            ),
          ),
          iconTheme: WidgetStateProperty.resolveWith<IconThemeData>(
            (Set<WidgetState> states) => IconThemeData(
              size: 20,
              color: states.contains(WidgetState.selected)
                  ? Console.cyan
                  : Console.dimText,
            ),
          ),
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
