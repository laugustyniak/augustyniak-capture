import 'package:flutter/material.dart';

import 'ui_kit.dart';

import '../features/recordings/presentation/recordings_page.dart';
import '../features/settings/domain/app_theme_mode.dart';

/// The app shell, and the one place the palette is chosen.
///
/// The theme is the only setting that has to live *above* `MaterialApp`, so it
/// cannot ride `SettingsController` the way every other one does — that
/// controller is owned by [RecordingsPage], which is `home:`. It travels up a
/// `ValueNotifier` instead: the shell writes the persisted value into it on
/// every settings change, and this widget is the only reader. One direction
/// only, so there is no second source of truth to keep in step.
class AugustyniakCaptureApp extends StatefulWidget {
  const AugustyniakCaptureApp({super.key});

  @override
  State<AugustyniakCaptureApp> createState() => _AugustyniakCaptureAppState();
}

class _AugustyniakCaptureAppState extends State<AugustyniakCaptureApp> {
  /// Starts on the OS setting, which is also what an install that never touched
  /// the Config tab resolves to — so the first frame and the frame after
  /// `settings.json` loads agree, and a fresh launch does not flash.
  final ValueNotifier<AppThemeMode> _themeMode = ValueNotifier<AppThemeMode>(
    AppThemeMode.system,
  );

  @override
  void dispose() {
    _themeMode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppThemeMode>(
      valueListenable: _themeMode,
      builder: (BuildContext context, AppThemeMode mode, Widget? _) {
        return MaterialApp(
          title: 'Augustyniak Capture',
          debugShowCheckedModeBanner: false,
          themeMode: switch (mode) {
            AppThemeMode.system => ThemeMode.system,
            AppThemeMode.dark => ThemeMode.dark,
            AppThemeMode.light => ThemeMode.light,
          },
          theme: consoleTheme(ConsolePalette.light),
          darkTheme: consoleTheme(ConsolePalette.dark),
          // The palette has to be in force *before* anything below paints, and
          // this is the only callback that runs under the resolved `Theme` but
          // ahead of `home`. Reading the brightness back off the theme rather
          // than re-deriving it from `mode` is what makes `system` correct: only
          // Material knows what the platform actually answered.
          builder: (BuildContext context, Widget? child) {
            Console.activate(
              Theme.of(context).brightness == Brightness.dark
                  ? ConsolePalette.dark
                  : ConsolePalette.light,
            );
            return child!;
          },
          home: RecordingsPage(themeMode: _themeMode),
        );
      },
    );
  }
}

/// One theme, built from one palette. Both brightnesses go through here, so a
/// surface that is themed in the dark cannot be left unthemed in the light.
ThemeData consoleTheme(ConsolePalette palette) {
  return ThemeData(
    brightness: palette.brightness,
    scaffoldBackgroundColor: palette.background,
    colorScheme: ColorScheme(
      brightness: palette.brightness,
      primary: palette.accent,
      onPrimary: palette.ink,
      secondary: palette.accentDeep,
      onSecondary: palette.ink,
      surface: palette.surface,
      onSurface: palette.text,
      error: palette.red,
      onError: palette.ink,
    ),
    useMaterial3: true,
    // Space Grotesk is the default face; anything factual opts into
    // JetBrains Mono explicitly through `ConsoleText`.
    fontFamily: ConsoleFont.display,
    textTheme: const TextTheme().apply(
      bodyColor: palette.text,
      displayColor: palette.text,
    ),
    cardTheme: CardThemeData(
      color: palette.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(12)),
        side: BorderSide(color: palette.border),
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: palette.background,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: palette.surfaceDeep,
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
              ? palette.accent
              : palette.dimText,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith<IconThemeData>(
        (Set<WidgetState> states) => IconThemeData(
          size: 20,
          color: states.contains(WidgetState.selected)
              ? palette.accent
              : palette.dimText,
        ),
      ),
    ),
    dialogTheme: DialogThemeData(backgroundColor: palette.surface),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: palette.background,
      surfaceTintColor: Colors.transparent,
    ),
  );
}
