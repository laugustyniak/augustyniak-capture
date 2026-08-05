import 'package:augustyniak_capture/features/gamification/data/gamification_repository.dart';
import 'package:augustyniak_capture/features/gamification/domain/gamification_stats.dart';
import 'package:augustyniak_capture/features/gamification/presentation/celebration_overlay.dart';
import 'package:augustyniak_capture/features/gamification/presentation/done_burst_animation.dart';
import 'package:augustyniak_capture/features/gamification/presentation/gamification_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeGamificationRepository extends GamificationRepository {
  @override
  Future<GamificationStats> load() async => const GamificationStats();

  @override
  Future<void> save(GamificationStats stats) async {}
}

void main() {
  testWidgets('CelebrationOverlay displays celebration banner on milestone', (WidgetTester tester) async {
    final GamificationController controller = GamificationController(
      repository: FakeGamificationRepository(),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: CelebrationOverlay(
          controller: controller,
          child: const Scaffold(body: Text('Main Content')),
        ),
      ),
    );

    expect(find.text('Main Content'), findsOneWidget);
    expect(find.text('PIERWSZE UKOŃCZONE!'), findsNothing);

    // Trigger first done milestone
    await controller.onCaptureDone(1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('PIERWSZE UKOŃCZONE!'), findsOneWidget);
    expect(find.text('WSPANIALE!'), findsOneWidget);

    // Dismiss by tapping button
    await tester.tap(find.text('WSPANIALE!'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    expect(find.text('PIERWSZE UKOŃCZONE!'), findsNothing);
  });

  testWidgets('DoneBurstAnimation renders child widget without error', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: DoneBurstAnimation(
            reviewed: true,
            child: Icon(Icons.check),
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.check), findsOneWidget);
  });
}
