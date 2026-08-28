import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:augustyniak_capture/app/app.dart';

void main() {
  testWidgets('AugustyniakCaptureApp renders and applies default textScaler', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const AugustyniakCaptureApp());
    await tester.pumpAndSettle();

    final BuildContext context = tester.element(find.byType(MaterialApp));
    final MediaQueryData mediaQuery = MediaQuery.of(context);
    expect(mediaQuery.textScaler.scale(10), 10.0);
  });

  testWidgets('AugustyniakCaptureApp reacts to textScale changes', (
    WidgetTester tester,
  ) async {
    final ValueNotifier<double> textScaleNotifier = ValueNotifier<double>(1.5);
    addTearDown(textScaleNotifier.dispose);

    await tester.pumpWidget(
      ValueListenableBuilder<double>(
        valueListenable: textScaleNotifier,
        builder: (BuildContext context, double scale, Widget? child) {
          return MaterialApp(
            builder: (BuildContext context, Widget? child) {
              return MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(scale),
                ),
                child: child!,
              );
            },
            home: const Scaffold(body: Text('Scale Test')),
          );
        },
      ),
    );
    await tester.pumpAndSettle();

    BuildContext textContext = tester.element(find.text('Scale Test'));
    expect(MediaQuery.of(textContext).textScaler.scale(10), 15.0);

    textScaleNotifier.value = 1.25;
    await tester.pumpAndSettle();

    textContext = tester.element(find.text('Scale Test'));
    expect(MediaQuery.of(textContext).textScaler.scale(10), 12.5);
  });
}
