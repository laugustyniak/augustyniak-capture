import 'package:augustyniak_capture/features/gamification/domain/milestone.dart';
import 'package:augustyniak_capture/features/gamification/presentation/milestone_copy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Milestone milestone(MilestoneType type, int count) => Milestone(
        id: '${type == MilestoneType.captureDone ? 'done' : 'capture'}_$count',
        type: type,
        count: count,
      );

  group('milestoneCopyFor', () {
    test('names the first capture and the first done differently', () {
      expect(
        milestoneCopyFor(milestone(MilestoneType.captureDone, 1)).title,
        equals('FIRST ONE DONE!'),
      );
      expect(
        milestoneCopyFor(milestone(MilestoneType.captureCreated, 1)).title,
        equals('FIRST CAPTURE!'),
      );
    });

    test('gives the 100th done its own wording', () {
      expect(
        milestoneCopyFor(milestone(MilestoneType.captureDone, 100)).title,
        equals('A HUNDRED DONE (100)!'),
      );
    });

    test('falls back to the counted wording above 300', () {
      final copy = milestoneCopyFor(milestone(MilestoneType.captureDone, 500));
      expect(copy.title, equals('500 DONE!'));
      expect(copy.icon, equals(Icons.celebration_rounded));
    });

    test('every tier maps to a distinct icon up to 300', () {
      final List<IconData> icons = <int>[1, 10, 20, 50, 100, 200, 300]
          .map((int c) => milestoneCopyFor(milestone(MilestoneType.captureDone, c)).icon)
          .toList();
      expect(icons.toSet().length, equals(icons.length));
    });

    test('no copy contains a Polish diacritic', () {
      final RegExp polish = RegExp('[ąćęłńóśźżĄĆĘŁŃÓŚŹŻ]');
      for (final MilestoneType type in MilestoneType.values) {
        for (final int count in <int>[1, 10, 20, 50, 100, 200, 300, 400]) {
          final copy = milestoneCopyFor(milestone(type, count));
          expect(copy.title, isNot(matches(polish)), reason: 'title for $type/$count');
          expect(copy.description, isNot(matches(polish)), reason: 'description for $type/$count');
        }
      }
    });
  });
}
