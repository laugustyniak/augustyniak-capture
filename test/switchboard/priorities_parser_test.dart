import 'package:augustyniak_capture/features/enrichment/domain/priorities_note.dart';
import 'package:flutter_test/flutter_test.dart';

// Every fixture here is invented. The repository is public: never paste text
// from a real note.
void main() {
  group('PrioritiesNote', () {
    // AC-2
    test('takes top-level list items in document order', () {
      final PrioritiesNote note = PrioritiesNote.parse(
        '# Focus\n'
        '\n'
        '- Ship the alpha build\n'
        '- Renew the domain\n'
        '- Draft the newsletter\n',
      );
      expect(note.items, <String>[
        'Ship the alpha build',
        'Renew the domain',
        'Draft the newsletter',
      ]);
      expect(note.tier, isNull);
      expect(note.status, isNull);
    });

    // AC-2
    test('strips ordered, bullet and checkbox markers', () {
      final PrioritiesNote note = PrioritiesNote.parse(
        '1. First thing\n'
        '2) Second thing\n'
        '* Third thing\n'
        '+ Fourth thing\n'
        '- [ ] Fifth thing\n'
        '- [x] Sixth thing\n',
      );
      expect(note.items, <String>[
        'First thing',
        'Second thing',
        'Third thing',
        'Fourth thing',
        'Fifth thing',
        'Sixth thing',
      ]);
    });

    // AC-2
    test('ignores nested items', () {
      final PrioritiesNote note = PrioritiesNote.parse(
        '- Parent one\n'
        '  - child a\n'
        '\t- child b\n'
        '    - grandchild\n'
        '- Parent two\n',
      );
      expect(note.items, <String>['Parent one', 'Parent two']);
    });

    // AC-2
    test('with no list, level-2 and deeper headings are the items', () {
      final PrioritiesNote note = PrioritiesNote.parse(
        '# Title is not an item\n'
        'Some prose.\n'
        '## Alpha project\n'
        'text\n'
        '### Beta project\n',
      );
      expect(note.items, <String>['Alpha project', 'Beta project']);
    });

    // AC-2
    test('a list wins over headings', () {
      final PrioritiesNote note = PrioritiesNote.parse(
        '## Heading ignored\n- Real item\n',
      );
      expect(note.items, <String>['Real item']);
    });

    // AC-2
    test('reads note-level tier and status from the frontmatter', () {
      final PrioritiesNote note = PrioritiesNote.parse(
        '---\n'
        'tier: 2\n'
        'status: active\n'
        '---\n'
        '- Only item\n',
      );
      expect(note.tier, 2);
      expect(note.status, 'active');
      expect(note.items, <String>['Only item']);
    });

    // AC-2
    test('frontmatter list items are never priorities', () {
      final PrioritiesNote note = PrioritiesNote.parse(
        '---\n'
        'tags:\n'
        '  - work\n'
        '- stray\n'
        'tier: 1\n'
        '---\n'
        '- Body item\n',
      );
      expect(note.items, <String>['Body item']);
    });

    // AC-2
    test('malformed frontmatter degrades to no tier and no status', () {
      final PrioritiesNote note = PrioritiesNote.parse(
        '---\n'
        'tier: [unclosed\n'
        'status: : :\n'
        '---\n'
        '- Body item\n',
      );
      expect(note.tier, isNull);
      expect(note.status, isNull);
    });

    // AC-2
    test('wikilinks are flattened, alias or not', () {
      final PrioritiesNote note = PrioritiesNote.parse(
        '- Finish [[project-alpha|the alpha]] soon\n'
        '- Review [[Budget plan]]\n',
      );
      expect(note.items, <String>[
        'Finish the alpha soon',
        'Review Budget plan',
      ]);
    });

    // AC-2
    test('caps at 20 items of 120 characters', () {
      final String body = <String>[
        for (int i = 0; i < 30; i++) '- Item number $i',
        '- ${'x' * 300}',
      ].join('\n');
      final PrioritiesNote note = PrioritiesNote.parse(body);
      expect(note.items, hasLength(20));
      expect(note.items.first, 'Item number 0');

      final PrioritiesNote long = PrioritiesNote.parse('- ${'y' * 300}');
      expect(long.items.single.length, lessThanOrEqualTo(120));
      expect(long.items.single, startsWith('yyyy'));
    });

    // AC-2
    test('empty, blank and garbage input give an empty list, never throw', () {
      for (final String input in <String>[
        '',
        '   \n\n ',
        'Just a paragraph of prose with no structure at all.',
        '\u0000\u0001\u0002 binary ��',
        '---\n---\n',
        '---\nunterminated frontmatter',
        '[[[[ ]]]] ** __ ``` ',
      ]) {
        final PrioritiesNote note = PrioritiesNote.parse(input);
        expect(note.items, isEmpty, reason: 'input: ${input.codeUnits}');
      }
    });
  });
}
