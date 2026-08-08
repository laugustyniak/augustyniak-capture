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
/// **The scan covers `lib/` only.** Native platform code under `ios/`,
/// `android/`, `macos/`, `linux/` and `windows/` is out of scope and is not
/// touched by this test at all — it has its own string-literal syntax that
/// this Dart-token regex cannot parse, and `flutter test` never compiles it
/// in the first place. Polish there has to be found by hand.
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
}
