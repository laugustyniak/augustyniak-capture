import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:augustyniak_capture/app/ui_kit.dart';

/// The only widget test in the suite: `CopyButton` is the one piece of UI whose
/// contract (what lands on the clipboard) cannot be checked in pure Dart.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> platformCalls;

  setUp(() {
    platformCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (
          MethodCall call,
        ) async {
          platformCalls.add(call);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> pumpButton(WidgetTester tester, String text) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: CopyButton(text: text)),
        ),
      ),
    );
  }

  String? copiedText() {
    for (final MethodCall call in platformCalls) {
      if (call.method == 'Clipboard.setData') {
        return (call.arguments as Map<Object?, Object?>)['text'] as String?;
      }
    }
    return null;
  }

  testWidgets('copies the full text, not the truncated render', (
    WidgetTester tester,
  ) async {
    // Far longer than the four lines the recording card shows.
    final String long = List<String>.generate(
      40,
      (int i) => 'Zdanie numer $i z pełnego transkryptu.',
    ).join(' ');

    await pumpButton(tester, long);
    await tester.tap(find.byType(CopyButton));
    await tester.pump();

    expect(copiedText(), long);

    // Let the feedback timer drain so the test ends with no pending timers.
    await tester.pump(const Duration(milliseconds: 1700));
  });

  testWidgets('icon confirms then settles back to the copy glyph', (
    WidgetTester tester,
  ) async {
    await pumpButton(tester, 'Dziękuję bardzo.');

    expect(find.byIcon(Icons.copy_rounded), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsNothing);

    await tester.tap(find.byType(CopyButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byIcon(Icons.check_rounded), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1700));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.copy_rounded), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsNothing);
  });

  testWidgets('surviving timer does not fire on a disposed element', (
    WidgetTester tester,
  ) async {
    await pumpButton(tester, 'krótki tekst');
    await tester.tap(find.byType(CopyButton));
    await tester.pump();

    // Scroll/rebuild the button out of the tree while the reset is pending.
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox())),
    );
    await tester.pump(const Duration(seconds: 2));

    expect(tester.takeException(), isNull);
  });

  testWidgets('empty text is still copied verbatim rather than skipped', (
    WidgetTester tester,
  ) async {
    await pumpButton(tester, '');
    await tester.tap(find.byType(CopyButton));
    await tester.pump();

    expect(copiedText(), '');
    await tester.pump(const Duration(milliseconds: 1700));
  });
}
