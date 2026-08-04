import 'dart:io';

import 'package:augustyniak_capture/app/app.dart';
import 'package:augustyniak_capture/app/ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// WCAG contrast between two opaque colours.
double _contrast(Color a, Color b) {
  final double la = a.computeLuminance();
  final double lb = b.computeLuminance();
  final double hi = la > lb ? la : lb;
  final double lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  group('ConsolePalette', () {
    // The two surfaces anything readable is ever drawn on. `surfaceRaised` is
    // excluded on purpose: it backs controls and fields, whose own foregrounds
    // are chosen at the call site.
    List<Color> surfacesOf(ConsolePalette p) => <Color>[
      p.background,
      p.surface,
    ];

    /// Every colour the palette documents as carrying *words*.
    Map<String, Color> textColoursOf(ConsolePalette p) => <String, Color>{
      'text': p.text,
      'textSoft': p.textSoft,
      'muted': p.muted,
      'mutedSoft': p.mutedSoft,
      'dimText': p.dimText,
      'accent': p.accent,
      'green': p.green,
      'amber': p.amber,
      'violet': p.violet,
      'pink': p.pink,
      'red': p.red,
      'redSoft': p.redSoft,
    };

    for (final (String name, ConsolePalette palette)
        in <(String, ConsolePalette)>[
          ('dark', ConsolePalette.dark),
          ('light', ConsolePalette.light),
        ]) {
      test('$name: every text colour clears AA on both surfaces', () {
        // The class comment makes this claim about `dimText` specifically, and
        // it is the one that has been wrong before: it used to carry the whole
        // 10.5 px `micro` scale at 3.63:1. Asserting the claim is what stops a
        // future palette edit from quietly repeating that.
        for (final MapEntry<String, Color> entry in textColoursOf(
          palette,
        ).entries) {
          for (final Color surface in surfacesOf(palette)) {
            expect(
              _contrast(entry.value, surface),
              greaterThanOrEqualTo(4.5),
              reason: '$name.${entry.key} on ${surface.toARGB32()}',
            );
          }
        }
      });

      test('$name: dim is legal for graphics and illegal for text', () {
        for (final Color surface in surfacesOf(palette)) {
          final double ratio = _contrast(palette.dim, surface);
          // 3:1 is the graphics floor it is documented as meeting…
          expect(ratio, greaterThanOrEqualTo(3.0), reason: '$name.dim');
          // …and staying under the text floor is what keeps it from creeping
          // back into labels: the moment it clears 4.5 it stops being
          // distinguishable from `dimText` and the three-level hierarchy
          // collapses into two.
          expect(ratio, lessThan(4.5), reason: '$name.dim');
        }
      });

      test('$name: ink is readable on an accent fill', () {
        expect(
          _contrast(palette.ink, palette.accent),
          greaterThanOrEqualTo(4.5),
        );
      });

      test('$name: the hairlines are visible against every surface', () {
        for (final Color surface in <Color>[
          palette.background,
          palette.surface,
          palette.surfaceRaised,
        ]) {
          // The reason both border values had to become opaque per theme: a
          // single translucent hairline cannot do this in two themes at once.
          expect(
            _contrast(palette.border, surface),
            greaterThan(1.1),
            reason: '$name.border on ${surface.toARGB32()}',
          );
        }
      });
    }

    test(
      'the two themes actually differ, and each names its own brightness',
      () {
        expect(ConsolePalette.dark.brightness, Brightness.dark);
        expect(ConsolePalette.light.brightness, Brightness.light);
        expect(
          ConsolePalette.dark.background,
          isNot(ConsolePalette.light.background),
        );
        expect(ConsolePalette.dark.text, isNot(ConsolePalette.light.text));
        // Dark backgrounds are dark and light ones are light — the one assertion
        // that catches a palette pasted into the wrong constant.
        expect(
          ConsolePalette.dark.background.computeLuminance(),
          lessThan(0.1),
        );
        expect(
          ConsolePalette.light.background.computeLuminance(),
          greaterThan(0.9),
        );
      },
    );

    test('activate swaps what Console hands out', () {
      addTearDown(() => Console.activate(ConsolePalette.dark));

      Console.activate(ConsolePalette.light);
      expect(Console.background, ConsolePalette.light.background);
      expect(Console.accent, ConsolePalette.light.accent);
      // The named styles read through the same getters, so they move with it.
      expect(ConsoleText.eyebrow.color, ConsolePalette.light.accent);

      Console.activate(ConsolePalette.dark);
      expect(Console.background, ConsolePalette.dark.background);
      expect(ConsoleText.eyebrow.color, ConsolePalette.dark.accent);
    });
  });

  group('consoleTheme', () {
    test('both brightnesses are built from the same function', () {
      // The point of one builder: a surface themed in the dark cannot be left
      // unthemed in the light, because there is no second place to forget it.
      for (final ConsolePalette palette in <ConsolePalette>[
        ConsolePalette.dark,
        ConsolePalette.light,
      ]) {
        final ThemeData theme = consoleTheme(palette);
        expect(theme.brightness, palette.brightness);
        expect(theme.colorScheme.brightness, palette.brightness);
        expect(theme.scaffoldBackgroundColor, palette.background);
        expect(theme.colorScheme.primary, palette.accent);
        expect(theme.colorScheme.surface, palette.surface);
        expect(theme.cardTheme.color, palette.surface);
        expect(theme.dialogTheme.backgroundColor, palette.surface);
        expect(theme.bottomSheetTheme.backgroundColor, palette.background);
        expect(theme.navigationBarTheme.backgroundColor, palette.surfaceDeep);
      }
    });

    test('it reads the palette it is given, not the active one', () {
      addTearDown(() => Console.activate(ConsolePalette.dark));
      Console.activate(ConsolePalette.dark);

      // Both themes are built on the same frame, under whichever palette
      // happens to be in force — so `consoleTheme` must never read the global.
      expect(
        consoleTheme(ConsolePalette.light).scaffoldBackgroundColor,
        ConsolePalette.light.background,
      );
    });
  });

  // The rule the whole runtime-theming design rests on, and the only one no
  // other test can observe: Flutter skips rebuilding a child `identical` to the
  // previous one, so a `const` widget that paints a palette colour keeps the
  // old theme on screen after a swap. Nothing about that is visible in a widget
  // test — the stale frame is a *correct* render of a stale widget — so it is
  // checked at the source level, the same way `rebrand_test.dart` pins the
  // application identifier.
  test('no const call site constructs a widget that paints the palette', () {
    final List<File> sources = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((File file) => file.path.endsWith('.dart'))
        .toList();

    final RegExp classHead = RegExp(r'class\s+(_?\w+)[^\n{]*\{');
    final RegExp constCall = RegExp(r'\bconst\s+(_?[A-Z]\w*)\s*\(');

    /// Every widget class whose body mentions the palette, plus the widget a
    /// `_FooState` belongs to — the state paints, the widget is what a caller
    /// would write `const` in front of.
    final Set<String> painters = <String>{};
    final Map<File, List<(String, int, int)>> classes =
        <File, List<(String, int, int)>>{};

    for (final File file in sources) {
      final String source = file.readAsStringSync();
      final List<(String, int, int)> spans = classHead
          .allMatches(source)
          .map((RegExpMatch m) => (m.group(1)!, m.start, m.end))
          .toList();
      classes[file] = spans;
      for (int i = 0; i < spans.length; i++) {
        final int end = i + 1 < spans.length ? spans[i + 1].$2 : source.length;
        final String body = source.substring(spans[i].$3, end);
        if (!body.contains('Console.') && !body.contains('ConsoleText.')) {
          continue;
        }
        final String name = spans[i].$1;
        final String base = name.startsWith('_') && name.endsWith('State')
            ? name.substring(1, name.length - 5)
            : name;
        painters.addAll(<String>[base, '_$base']);
      }
    }

    final List<String> offenders = <String>[];
    for (final File file in sources) {
      final String source = file.readAsStringSync();
      for (final RegExpMatch match in constCall.allMatches(source)) {
        final String name = match.group(1)!;
        if (!painters.contains(name)) continue;
        // The constructor's own declaration is fine and required — it is only a
        // caller writing `const` that pins a widget instance forever.
        String? enclosing;
        for (final (String, int, int) span in classes[file]!) {
          if (span.$2 <= match.start) {
            enclosing = span.$1;
          } else {
            break;
          }
        }
        if (enclosing == name) continue;
        final int line =
            '\n'.allMatches(source.substring(0, match.start)).length + 1;
        offenders.add('${file.path}:$line const $name(');
      }
    }

    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });

  // The same staleness one level up, and the one that actually shipped: a
  // top-level `InputDecoration _fieldDecoration = InputDecoration(… Console.…)`
  // is initialised lazily **once**, so the first field ever built pins that
  // theme's colours into every field for the rest of the process. There is no
  // compiler error and no wrong-looking frame in a single-theme run.
  test('no top-level variable caches a palette colour', () {
    // `(?![ \t])` is what makes this a *top-level* scan: with `multiLine` the
    // anchor sits at every line start, and a space inside the type character
    // class would otherwise let every indented local match.
    final RegExp declaration = RegExp(
      r'^(?![ \t])(?!.*\bget\b)[\w<>,?\[\] ]+\s+_?\w+\s*=',
      multiLine: true,
    );

    final List<String> offenders = <String>[];
    for (final File file in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((File file) => file.path.endsWith('.dart'))) {
      final String source = file.readAsStringSync();
      for (final RegExpMatch match in declaration.allMatches(source)) {
        // Column 0 only: anything indented is inside a class or a function, and
        // a field or a local is re-evaluated per instance or per call.
        if (match.start != 0 && source[match.start - 1] != '\n') continue;
        final int end = source.indexOf(';', match.end);
        if (end < 0) continue;
        if (!source.substring(match.end, end).contains('Console.')) continue;
        final int line =
            '\n'.allMatches(source.substring(0, match.start)).length + 1;
        offenders.add('${file.path}:$line ${match.group(0)!.trim()}');
      }
    }

    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });
}
