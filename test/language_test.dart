import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `CLAUDE.md`: "user-facing strings in code are English (they were Polish
/// until the design pass — do not reintroduce Polish)". Nothing enforced that
/// until this file, and two features drifted back.
///
/// **This is a tripwire, not a proof.** The diacritic scan is structural and
/// needs no upkeep. The wordlist is a heuristic with false negatives by
/// construction: a Polish string using none of those words passes. It exists
/// because a diacritic-only scan of this repository missed nine strings —
/// 'WSPANIALE!', 'Anuluj', 'Dodaj', 'Wszystkie', 'Nowa', 'Wyczyszcz',
/// '[Obrazek]', 'min temu', 'Schowek jest pusty' — and reported one of their
/// files as clean. Do not read a green run here as "the UI is English".
///
/// **Two scans, deliberately unequal.** The `lib/` scan reads string literals
/// and skips comments, because `hotkey_binding.dart` legitimately lists
/// `ą/ć/ę/ł/ń/ó/ś/ź/ż` while explaining AltGr. The native scan reads whole
/// files, comments included: no native file has an equivalent case, `CLAUDE.md`
/// asks for English in comments too, and `.plist`/`.xml` carry user-facing text
/// in nodes rather than in literals — `NSMicrophoneUsageDescription` is what
/// the OS shows in the microphone consent dialog. A raw scan of all 52 native
/// sources produced zero false positives, so the Dart tokenizer would buy
/// nothing there and would miss the XML entirely.
void main() {
  // Files allowed to hold Polish, each for a reason that is not display text.
  const Map<String, String> allowed = <String, String>{
    'lib/features/recordings/data/markdown_note_vault.dart':
        'the ą→a transliteration map — data, not display text',
    'lib/features/enrichment/domain/enrichment_defaults.dart':
        'Polish examples inside an English LLM prompt, teaching the model to '
        'recognise Polish imperatives. Removing them degrades classification.',
  };

  // One pass, left to right, so a `//` inside a string literal is consumed as
  // part of the literal rather than treated as the start of a comment. Order
  // matters: triple quotes before single, raw strings before bare.
  //
  // A quote character inside string interpolation (e.g. `'…${x.padLeft(2,
  // '0')}…'`) closes this pattern's literal early and lets it re-open on the
  // inner quote. Every character of textual content is still visited by some
  // match, so coverage is not weakened — only the token boundaries reported
  // in an offence line can look wrong for such a literal. That is a cosmetic
  // artifact of the tokenizer, not a scanning gap; do not chase it as a bug.
  final RegExp tokens = RegExp(
    r"r?'''[\s\S]*?'''"
    r'|r?"""[\s\S]*?"""'
    r"|r?'(?:[^'\\\n]|\\.)*'"
    r'|r?"(?:[^"\\\n]|\\.)*"'
    r'|//[^\n]*'
    r'|/\*[\s\S]*?\*/',
  );

  final RegExp diacritics = RegExp('[ąćęłńóśźżĄĆĘŁŃÓŚŹŻ]');
  // `\b` is defined against ASCII `\w`, so a Polish letter never counts as a
  // word character to it. A trailing `\b` right after a diacritic (e.g. the
  // 'ń' in 'usuń') sits between two characters `\b` sees as non-word and
  // never matches, silently killing any diacritic-final entry; a leading
  // `\b` before a diacritic-initial word would fail the same way. The
  // lookaround below treats the Polish alphabet as an extension of `\w` on
  // both sides so entries of either shape actually match.
  const String wordCharOrPolish = r'a-zA-Z0-9_ąćęłńóśźżĄĆĘŁŃÓŚŹŻ';
  final RegExp polishWords = RegExp(
    '(?<![$wordCharOrPolish])'
    r'(nie|jest|oraz|aby|temu|przez|dla|lub|brak|wszystkie|anuluj|dodaj'
    r'|usuń|nowa|nowy|pusty|obrazek|kolekcja|wyczyść|zapisz|zamknij|otwórz'
    r'|szukaj|wspaniale|nazwa|schowek)'
    '(?![$wordCharOrPolish])',
    caseSensitive: false,
  );

  test('no Polish in user-facing string literals under lib/', () {
    final List<String> offences = <String>[];

    final List<File> sources = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((File f) => f.path.endsWith('.dart'))
        .toList();

    expect(sources, isNotEmpty, reason: 'run this from the repository root');

    for (final File file in sources) {
      final String relative = file.path.replaceAll(r'\', '/');
      if (allowed.containsKey(relative)) continue;

      final String source = file.readAsStringSync();
      for (final RegExpMatch match in tokens.allMatches(source)) {
        final String token = match.group(0)!;
        if (token.startsWith('//') || token.startsWith('/*')) continue;

        if (!diacritics.hasMatch(token) && !polishWords.hasMatch(token)) {
          continue;
        }

        final int line = '\n'.allMatches(source.substring(0, match.start)).length + 1;
        offences.add('$relative:$line  $token');
      }
    }

    expect(
      offences,
      isEmpty,
      reason: 'Polish string literals found. Translate them, or — if the text '
          'is data rather than display copy — add the file to `allowed` above '
          'with the reason:\n${offences.join('\n')}',
    );
  });

  test('every allowlisted file exists and still earns its exemption', () {
    // An allowlist entry for a moved or deleted file is a silent hole: the
    // scan would skip nothing and nobody would know the reason had expired.
    //
    // The bigger hole is a file that still exists but no longer needs the
    // exemption: the allowlist is file-level, so a stale entry silences the
    // scan for that whole file indefinitely, not just for the Polish that
    // justified it. So beyond existing, each file must still contain a token
    // the main scan would flag — otherwise the entry is exempting nothing and
    // should be deleted.
    for (final String path in allowed.keys) {
      final File file = File(path);
      expect(file.existsSync(), isTrue, reason: '$path is allowlisted but missing');

      final String source = file.readAsStringSync();
      final bool stillHasPolish = tokens.allMatches(source).any((RegExpMatch match) {
        final String token = match.group(0)!;
        if (token.startsWith('//') || token.startsWith('/*')) return false;
        return diacritics.hasMatch(token) || polishWords.hasMatch(token);
      });
      expect(
        stillHasPolish,
        isTrue,
        reason: '$path is allowlisted (${allowed[path]}) but no longer contains '
            'anything the scan would flag — the exemption is stale and should '
            'be removed.',
      );
    }
  });

  test('no Polish in native platform sources', () {
    const List<String> platformDirs = <String>[
      'ios',
      'android',
      'macos',
      'linux',
      'windows',
    ];
    const List<String> extensions = <String>[
      '.swift',
      '.kt',
      '.java',
      '.m',
      '.h',
      '.cc',
      '.cpp',
      '.xml',
      '.plist',
      '.storyboard',
      '.xib',
    ];
    // `build`/`ephemeral` are ordinary directories; `.symlinks` is not — it
    // points into the pub cache, and `listSync` follows links by default, so
    // the walk below also passes `followLinks: false`. Both are needed: the
    // flag handles the symlink, the filter handles the directories.
    const Set<String> skippedSegments = <String>{
      'build',
      'Pods',
      'ephemeral',
      '.gradle',
      '.symlinks',
      'DerivedData',
    };

    final List<File> sources = <File>[];
    for (final String dir in platformDirs) {
      final Directory root = Directory(dir);
      if (!root.existsSync()) continue;
      for (final FileSystemEntity entity
          in root.listSync(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final String relative = entity.path.replaceAll(r'\', '/');
        if (relative.split('/').any(skippedSegments.contains)) continue;
        if (!extensions.any(relative.endsWith)) continue;
        sources.add(entity);
      }
    }

    // The most important assertion in this test. A typo in a directory name or
    // an extension, or a skip rule one segment too broad, otherwise yields a
    // test that passes forever while scanning nothing.
    expect(
      sources,
      isNotEmpty,
      reason: 'the native scan matched no files at all — it is checking '
          'nothing. Run from the repository root, and check platformDirs, '
          'extensions and skippedSegments before trusting a green run.',
    );

    final List<String> offences = <String>[];
    for (final File file in sources) {
      final String relative = file.path.replaceAll(r'\', '/');
      final List<String> lines = file.readAsStringSync().split('\n');
      for (int i = 0; i < lines.length; i++) {
        final String line = lines[i];
        if (!diacritics.hasMatch(line) && !polishWords.hasMatch(line)) {
          continue;
        }
        final String trimmed = line.trim();
        final String shown =
            trimmed.length > 120 ? '${trimmed.substring(0, 120)}…' : trimmed;
        offences.add('$relative:${i + 1}  $shown');
      }
    }

    expect(
      offences,
      isEmpty,
      reason: 'Polish found in native platform sources. Unlike the lib/ scan '
          'this one reads whole files, comments included — CLAUDE.md asks for '
          'English there too. Translate it. If a native file ever has a '
          'genuine reason to hold Polish, add an allowlist here rather than '
          'narrowing the scan:\n${offences.join('\n')}',
    );
  });
}
