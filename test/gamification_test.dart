import 'package:augustyniak_capture/features/gamification/data/gamification_repository.dart';
import 'package:augustyniak_capture/features/gamification/domain/gamification_stats.dart';
import 'package:augustyniak_capture/features/gamification/domain/milestone.dart';
import 'package:augustyniak_capture/features/gamification/presentation/gamification_controller.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeGamificationRepository extends GamificationRepository {
  GamificationStats _stored = const GamificationStats();

  @override
  Future<GamificationStats> load() async => _stored;

  @override
  Future<void> save(GamificationStats stats) async {
    _stored = stats;
  }
}

void main() {
  group('Milestone rules', () {
    test('identifies milestone counts correctly', () {
      expect(Milestone.isMilestoneCount(1), isTrue);
      expect(Milestone.isMilestoneCount(10), isTrue);
      expect(Milestone.isMilestoneCount(20), isTrue);
      expect(Milestone.isMilestoneCount(50), isTrue);
      expect(Milestone.isMilestoneCount(100), isTrue);
      expect(Milestone.isMilestoneCount(200), isTrue);
      expect(Milestone.isMilestoneCount(300), isTrue);
      expect(Milestone.isMilestoneCount(400), isTrue);
      expect(Milestone.isMilestoneCount(500), isTrue);
      expect(Milestone.isMilestoneCount(1000), isTrue);

      expect(Milestone.isMilestoneCount(0), isFalse);
      expect(Milestone.isMilestoneCount(2), isFalse);
      expect(Milestone.isMilestoneCount(15), isFalse);
      expect(Milestone.isMilestoneCount(250), isFalse);
      expect(Milestone.isMilestoneCount(450), isFalse);
    });

    test('creates milestone details for 1st, 10th, 100th done and captures', () {
      final Milestone? firstDone = Milestone.check(
        type: MilestoneType.captureDone,
        currentCount: 1,
        unlockedIds: const <String>{},
      );

      expect(firstDone, isNotNull);
      expect(firstDone!.id, equals('done_1'));
      expect(firstDone.title, contains('PIERWSZE UKOŃCZONE!'));

      final Milestone? hundredDone = Milestone.check(
        type: MilestoneType.captureDone,
        currentCount: 100,
        unlockedIds: const <String>{},
      );
      expect(hundredDone, isNotNull);
      expect(hundredDone!.id, equals('done_100'));
      expect(hundredDone.title, contains('SETKA ZROBIONA (100)!'));
    });

    test('ignores already unlocked milestones', () {
      final Milestone? repeatDone = Milestone.check(
        type: MilestoneType.captureDone,
        currentCount: 1,
        unlockedIds: const <String>{'done_1'},
      );

      expect(repeatDone, isNull);
    });
  });

  group('GamificationStats JSON', () {
    test('serializes and deserializes correctly', () {
      const GamificationStats stats = GamificationStats(
        totalCapturesCreated: 15,
        totalCapturesDone: 10,
        unlockedMilestones: <String>{'capture_1', 'capture_10', 'done_1', 'done_10'},
      );

      final Map<String, dynamic> json = stats.toJson();
      final GamificationStats restored = GamificationStats.fromJson(json);

      expect(restored.totalCapturesCreated, equals(15));
      expect(restored.totalCapturesDone, equals(10));
      expect(restored.unlockedMilestones, containsAll(<String>[
        'capture_1',
        'capture_10',
        'done_1',
        'done_10',
      ]));
    });
  });

  group('GamificationController', () {
    test('triggers celebration on 1st capture and 1st done', () async {
      final FakeGamificationRepository repo = FakeGamificationRepository();
      final GamificationController controller = GamificationController(
        repository: repo,
      );

      await controller.initialize();
      expect(controller.pendingMilestone, isNull);

      await controller.onCaptureCreated(1);
      expect(controller.pendingMilestone, isNotNull);
      expect(controller.pendingMilestone!.id, equals('capture_1'));

      controller.dismissMilestone();
      expect(controller.pendingMilestone, isNull);

      await controller.onCaptureDone(1);
      expect(controller.pendingMilestone, isNotNull);
      expect(controller.pendingMilestone!.id, equals('done_1'));
    });

    test('triggers milestones at 10, 20, 50, 100, 200, 300 and every 100', () async {
      final FakeGamificationRepository repo = FakeGamificationRepository();
      final GamificationController controller = GamificationController(
        repository: repo,
      );

      await controller.initialize();

      for (final int target in <int>[10, 20, 50, 100, 200, 300, 400, 500]) {
        await controller.onCaptureDone(target);
        expect(controller.pendingMilestone, isNotNull);
        expect(controller.pendingMilestone!.count, equals(target));
        controller.dismissMilestone();
      }
    });
  });
}
