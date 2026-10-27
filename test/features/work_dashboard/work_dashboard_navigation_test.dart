import 'package:augustyniak_capture/app/app.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Work destination opens the Todoist dashboard', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const AugustyniakCaptureApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('WORK').first);
    await tester.pump();

    expect(find.text('Work'), findsOneWidget);
    expect(find.text('TODOIST + CAPTURE'), findsOneWidget);
  });
}
