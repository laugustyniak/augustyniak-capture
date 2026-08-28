import 'package:flutter_test/flutter_test.dart';

import 'package:augustyniak_capture/app/markdown/simple_markdown.dart';

/// The spans of any block that carries them — the blocks themselves have no
/// value equality, so every assertion below compares types and span lists.
List<MarkdownSpan> spansOf(MarkdownBlock block) => switch (block) {
  MarkdownHeading(spans: final List<MarkdownSpan> s) => s,
  MarkdownParagraph(spans: final List<MarkdownSpan> s) => s,
  MarkdownBullet(spans: final List<MarkdownSpan> s) => s,
  MarkdownNumbered(spans: final List<MarkdownSpan> s) => s,
  MarkdownQuote(spans: final List<MarkdownSpan> s) => s,
  MarkdownCode() => const <MarkdownSpan>[],
  MarkdownRule() => const <MarkdownSpan>[],
};

/// The plain text a block renders, markers already resolved.
String textOf(MarkdownBlock block) =>
    spansOf(block).map((MarkdownSpan s) => s.text).join();

void main() {
  group('empty input', () {
    test('empty and whitespace-only sources produce no blocks', () {
      expect(parseSimpleMarkdown(''), isEmpty);
      expect(parseSimpleMarkdown('   '), isEmpty);
      expect(parseSimpleMarkdown('\n\n  \n\t\n'), isEmpty);
    });
  });

  group('blocks', () {
    test('ATX headings carry their level, clamped at three', () {
      final List<MarkdownBlock> blocks = parseSimpleMarkdown(
        '# One\n\n## Two\n\n### Three\n\n#### Four\n\n###### Six',
      );

      expect(blocks, hasLength(5));
      expect(
        blocks.map((MarkdownBlock b) => (b as MarkdownHeading).level),
        <int>[1, 2, 3, 3, 3],
      );
      expect(textOf(blocks.first), 'One');
      expect(textOf(blocks.last), 'Six');
    });

    test('a hash with no space after it is not a heading', () {
      final List<MarkdownBlock> blocks = parseSimpleMarkdown('#hashtag');

      expect(blocks.single, isA<MarkdownParagraph>());
      expect(textOf(blocks.single), '#hashtag');
    });

    test(
      'a paragraph keeps its soft line breaks and splits on a blank line',
      () {
        final List<MarkdownBlock> blocks = parseSimpleMarkdown(
          'first line\nsecond line\n\nnext paragraph',
        );

        expect(blocks, hasLength(2));
        expect(textOf(blocks.first), 'first line\nsecond line');
        expect(textOf(blocks.last), 'next paragraph');
      },
    );

    test('bullets accept all three markers', () {
      final List<MarkdownBlock> blocks = parseSimpleMarkdown(
        '- dash\n* star\n+ plus',
      );

      expect(blocks, hasLength(3));
      expect(blocks.every((MarkdownBlock b) => b is MarkdownBullet), isTrue);
      expect(blocks.map(textOf), <String>['dash', 'star', 'plus']);
      expect(
        blocks.map((MarkdownBlock b) => (b as MarkdownBullet).depth),
        <int>[0, 0, 0],
      );
    });

    test('two spaces or a tab nest a bullet one level deeper', () {
      final List<MarkdownBlock> blocks = parseSimpleMarkdown(
        '- top\n  - nested\n    - deeper\n\t- tabbed',
      );

      expect(
        blocks.map((MarkdownBlock b) => (b as MarkdownBullet).depth),
        <int>[0, 1, 2, 1],
      );
      expect(textOf(blocks[1]), 'nested');
    });

    test('numbered items keep their own number and depth', () {
      final List<MarkdownBlock> blocks = parseSimpleMarkdown(
        '1. first\n2. second\n  3. nested\n7. seventh',
      );

      final List<MarkdownNumbered> items = blocks.cast<MarkdownNumbered>();
      expect(items.map((MarkdownNumbered n) => n.number), <int>[1, 2, 3, 7]);
      expect(items.map((MarkdownNumbered n) => n.depth), <int>[0, 0, 1, 0]);
      expect(textOf(items.first), 'first');
    });

    test('consecutive quote lines merge into one block with soft breaks', () {
      final List<MarkdownBlock> blocks = parseSimpleMarkdown(
        '> quoted\n> still quoted\n\nafter',
      );

      expect(blocks, hasLength(2));
      expect(blocks.first, isA<MarkdownQuote>());
      expect(textOf(blocks.first), 'quoted\nstill quoted');
      expect(blocks.last, isA<MarkdownParagraph>());
    });

    test('a fenced code block keeps its text verbatim and its language', () {
      final List<MarkdownBlock> blocks = parseSimpleMarkdown(
        '```dart\nvoid main() {}\n  indented *not* emphasised\n```\nafter',
      );

      final MarkdownCode code = blocks.first as MarkdownCode;
      expect(code.language, 'dart');
      expect(code.text, 'void main() {}\n  indented *not* emphasised');
      expect(blocks.last, isA<MarkdownParagraph>());
    });

    test('a fence with no language leaves it null', () {
      final MarkdownCode code =
          parseSimpleMarkdown('```\nplain\n```').single as MarkdownCode;

      expect(code.language, isNull);
      expect(code.text, 'plain');
    });

    test('an unterminated fence runs to the end of the input', () {
      final List<MarkdownBlock> blocks = parseSimpleMarkdown(
        'intro\n\n```sh\nflutter test\nstill code\n',
      );

      expect(blocks, hasLength(2));
      final MarkdownCode code = blocks.last as MarkdownCode;
      expect(code.language, 'sh');
      expect(code.text, 'flutter test\nstill code');
    });

    test('horizontal rules take all three forms on their own line', () {
      final List<MarkdownBlock> blocks = parseSimpleMarkdown(
        'a\n\n---\n\n***\n\n___\n\nb',
      );

      expect(blocks.whereType<MarkdownRule>(), hasLength(3));
      expect(blocks.first, isA<MarkdownParagraph>());
      expect(blocks.last, isA<MarkdownParagraph>());
    });

    test('a two-dash line is text, not a rule', () {
      expect(parseSimpleMarkdown('--').single, isA<MarkdownParagraph>());
    });

    test('a heading interrupts a paragraph with no blank line between', () {
      final List<MarkdownBlock> blocks = parseSimpleMarkdown(
        'some prose\n# Heading\nmore prose',
      );

      expect(blocks, hasLength(3));
      expect(textOf(blocks[0]), 'some prose');
      expect((blocks[1] as MarkdownHeading).level, 1);
      expect(textOf(blocks[2]), 'more prose');
    });

    test('a bullet interrupts a paragraph with no blank line between', () {
      final List<MarkdownBlock> blocks = parseSimpleMarkdown(
        'shopping:\n- milk\n- bread',
      );

      expect(blocks, hasLength(3));
      expect(blocks[0], isA<MarkdownParagraph>());
      expect(blocks[1], isA<MarkdownBullet>());
      expect(blocks[2], isA<MarkdownBullet>());
    });

    test('CRLF input parses exactly as the LF form does', () {
      final List<MarkdownBlock> blocks = parseSimpleMarkdown(
        '# Title\r\n\r\nbody one\r\nbody two\r\n\r\n- item\r\n',
      );

      expect(blocks, hasLength(3));
      expect((blocks[0] as MarkdownHeading).level, 1);
      expect(textOf(blocks[0]), 'Title');
      expect(textOf(blocks[1]), 'body one\nbody two');
      expect(blocks[2], isA<MarkdownBullet>());
      expect(textOf(blocks[2]), 'item');
      for (final MarkdownBlock block in blocks) {
        expect(textOf(block), isNot(contains('\r')));
      }
    });

    test('a lone carriage return is a line break too', () {
      final List<MarkdownBlock> blocks = parseSimpleMarkdown('# Old Mac\rbody');

      expect(blocks, hasLength(2));
      expect(textOf(blocks.first), 'Old Mac');
    });
  });

  group('inline emphasis', () {
    test('bold and italic in both marker styles', () {
      expect(spansOf(parseSimpleMarkdown('a **b** c').single), <MarkdownSpan>[
        const MarkdownSpan('a '),
        const MarkdownSpan('b', bold: true),
        const MarkdownSpan(' c'),
      ]);
      expect(spansOf(parseSimpleMarkdown('a __b__ c').single), <MarkdownSpan>[
        const MarkdownSpan('a '),
        const MarkdownSpan('b', bold: true),
        const MarkdownSpan(' c'),
      ]);
      expect(spansOf(parseSimpleMarkdown('a *b* c').single), <MarkdownSpan>[
        const MarkdownSpan('a '),
        const MarkdownSpan('b', italic: true),
        const MarkdownSpan(' c'),
      ]);
      expect(spansOf(parseSimpleMarkdown('a _b_ c').single), <MarkdownSpan>[
        const MarkdownSpan('a '),
        const MarkdownSpan('b', italic: true),
        const MarkdownSpan(' c'),
      ]);
    });

    test('italic nests inside bold', () {
      expect(
        spansOf(parseSimpleMarkdown('**bold *and* more**').single),
        <MarkdownSpan>[
          const MarkdownSpan('bold ', bold: true),
          const MarkdownSpan('and', bold: true, italic: true),
          const MarkdownSpan(' more', bold: true),
        ],
      );
    });

    test('emphasis is parsed inside headings, bullets and quotes too', () {
      expect(
        spansOf(parseSimpleMarkdown('# a **b**').single).last,
        const MarkdownSpan('b', bold: true),
      );
      expect(
        spansOf(parseSimpleMarkdown('- a *b*').single).last,
        const MarkdownSpan('b', italic: true),
      );
      expect(
        spansOf(parseSimpleMarkdown('> a `b`').single).last,
        const MarkdownSpan('b', code: true),
      );
    });

    test('an inline code span wins over every marker inside it', () {
      expect(
        spansOf(parseSimpleMarkdown('run `a **b** _c_` now').single),
        <MarkdownSpan>[
          const MarkdownSpan('run '),
          const MarkdownSpan('a **b** _c_', code: true),
          const MarkdownSpan(' now'),
        ],
      );
    });

    test('a code span hides a marker that would otherwise pair up', () {
      // The `*` inside the code span must not close the emphasis outside it.
      expect(spansOf(parseSimpleMarkdown('`*` alone').single), <MarkdownSpan>[
        const MarkdownSpan('*', code: true),
        const MarkdownSpan(' alone'),
      ]);
    });
  });

  group('dictated prose keeps its stray markers', () {
    test('arithmetic with spaced asterisks stays literal', () {
      expect(textOf(parseSimpleMarkdown('5 * 3 = 15').single), '5 * 3 = 15');
      expect(
        spansOf(parseSimpleMarkdown('5 * 3 = 15 * 2').single).single.italic,
        isFalse,
      );
    });

    test('snake_case identifiers keep their underscores', () {
      final MarkdownBlock block = parseSimpleMarkdown(
        'call snake_case_name and other_thing here',
      ).single;

      expect(textOf(block), 'call snake_case_name and other_thing here');
      expect(spansOf(block).every((MarkdownSpan s) => !s.italic), isTrue);
    });

    test('a single unmatched marker stays literal', () {
      expect(textOf(parseSimpleMarkdown('wait *what').single), 'wait *what');
      expect(textOf(parseSimpleMarkdown('a ** b').single), 'a ** b');
      expect(
        textOf(parseSimpleMarkdown('an _ underscore').single),
        'an _ underscore',
      );
      expect(
        spansOf(
          parseSimpleMarkdown('wait *what').single,
        ).every((MarkdownSpan s) => !s.italic && !s.bold),
        isTrue,
      );
    });

    test('an unmatched backtick stays literal', () {
      expect(textOf(parseSimpleMarkdown('a ` b').single), 'a ` b');
      expect(
        spansOf(
          parseSimpleMarkdown('a ` b').single,
        ).every((MarkdownSpan s) => !s.code),
        isTrue,
      );
    });

    test('emphasis never opens on trailing whitespace or closes on leading', () {
      // `* text *` — both markers are flanked by whitespace, so neither pairs.
      expect(
        textOf(parseSimpleMarkdown('a * text * b').single),
        'a * text * b',
      );
    });

    test(
      'a marker cannot open emphasis on whitespace, even with a partner',
      () {
        // The closer rule alone does not save this one: the trailing `*` is a
        // perfectly good closer, so only refusing to *open* on whitespace keeps
        // the sentence intact.
        expect(
          textOf(parseSimpleMarkdown('total * cost*').single),
          'total * cost*',
        );
        expect(
          spansOf(
            parseSimpleMarkdown('total * cost*').single,
          ).every((MarkdownSpan s) => !s.italic),
          isTrue,
        );
      },
    );

    test('a marker inside a word does not open emphasis', () {
      expect(textOf(parseSimpleMarkdown('2*3*4').single), '2*3*4');
    });

    test('a bracket that is not a link stays literal', () {
      expect(
        textOf(parseSimpleMarkdown('see [the notes] for detail').single),
        'see [the notes] for detail',
      );
      expect(
        textOf(parseSimpleMarkdown('an [unclosed link( here').single),
        'an [unclosed link( here',
      );
    });
  });

  group('escapes', () {
    test('a backslash before a marker emits the literal marker', () {
      expect(
        textOf(parseSimpleMarkdown(r'\*not italic\*').single),
        '*not italic*',
      );
      expect(textOf(parseSimpleMarkdown(r'a \_b\_ c').single), 'a _b_ c');
      expect(textOf(parseSimpleMarkdown(r'\`code\`').single), '`code`');
      expect(
        textOf(parseSimpleMarkdown(r'\[label](url)').single),
        '[label](url)',
      );
      expect(
        spansOf(
          parseSimpleMarkdown(r'\*not italic\*').single,
        ).every((MarkdownSpan s) => !s.italic),
        isTrue,
      );
    });

    test('an escaped backslash is one backslash', () {
      expect(textOf(parseSimpleMarkdown(r'a \\ b').single), r'a \ b');
    });

    test('a backslash before an ordinary letter stays literal', () {
      expect(textOf(parseSimpleMarkdown(r'C:\path\to').single), r'C:\path\to');
    });
  });

  group('links', () {
    test('an inline link carries its href and its label', () {
      expect(
        spansOf(
          parseSimpleMarkdown(
            'see [the docs](https://example.com/a) now',
          ).single,
        ),
        <MarkdownSpan>[
          const MarkdownSpan('see '),
          const MarkdownSpan('the docs', href: 'https://example.com/a'),
          const MarkdownSpan(' now'),
        ],
      );
    });

    test('a link label may carry emphasis', () {
      expect(
        spansOf(parseSimpleMarkdown('[**bold** link](https://x.dev)').single),
        <MarkdownSpan>[
          const MarkdownSpan('bold', bold: true, href: 'https://x.dev'),
          const MarkdownSpan(' link', href: 'https://x.dev'),
        ],
      );
    });

    test('an autolink renders its own url', () {
      expect(
        spansOf(parseSimpleMarkdown('at <https://example.com/x> today').single),
        <MarkdownSpan>[
          const MarkdownSpan('at '),
          const MarkdownSpan(
            'https://example.com/x',
            href: 'https://example.com/x',
          ),
          const MarkdownSpan(' today'),
        ],
      );
    });

    test('an angle bracket that is not a url stays literal', () {
      expect(
        textOf(parseSimpleMarkdown('a < b and c > d').single),
        'a < b and c > d',
      );
      expect(textOf(parseSimpleMarkdown('<not a url>').single), '<not a url>');
    });
  });

  group('span equality', () {
    test('spans compare by value', () {
      expect(
        const MarkdownSpan('a', bold: true),
        const MarkdownSpan('a', bold: true),
      );
      expect(
        const MarkdownSpan('a', bold: true).hashCode,
        const MarkdownSpan('a', bold: true).hashCode,
      );
      expect(
        const MarkdownSpan('a', bold: true),
        isNot(const MarkdownSpan('a', italic: true)),
      );
      expect(
        const MarkdownSpan('a', href: 'x'),
        isNot(const MarkdownSpan('a')),
      );
    });
  });

  group('bounded work', () {
    test('a long transcript full of stray markers parses promptly', () {
      // No backtick in the repeat: two of those would pair into a real code
      // span and legitimately consume their own delimiters. The single stray
      // one at the end is the unmatched case, and it has to survive.
      final String prose =
          '${List<String>.filled(2000, 'a * b _ c [ d ] ( e ) < f > ').join()}`';
      final Stopwatch watch = Stopwatch()..start();

      final List<MarkdownBlock> blocks = parseSimpleMarkdown(prose);

      watch.stop();
      expect(blocks, hasLength(1));
      expect(textOf(blocks.single), prose);
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    });
  });

  group('preview text', () {
    test('drops the markers a fixed-height excerpt cannot render', () {
      expect(
        markdownPreviewText('## Plan\n\n- call the **joiner**\n'),
        'Plan\ncall the joiner',
      );
    });

    test('keeps prose that only looks like markup', () {
      expect(
        markdownPreviewText('5 * 3 = 15 in snake_case_name'),
        '5 * 3 = 15 in snake_case_name',
      );
    });

    test('parses only the head, however long the capture is', () {
      // The excerpt is three lines; walking ninety minutes of transcript on
      // every rebuild of the row is the cost this bound exists to refuse.
      final String long = '# Head\n\n${'word ' * 5000}';
      expect(markdownPreviewText(long, maxChars: 40), startsWith('Head\nword'));
      expect(markdownPreviewText(long, maxChars: 40).length, lessThan(60));
    });

    test('a fenced block keeps its code and loses its fence', () {
      expect(markdownPreviewText('```dart\nfinal x = 1;\n```'), 'final x = 1;');
    });
  });
}
