import 'package:augustyniak_capture/features/costs/domain/model_price.dart';
import 'package:augustyniak_capture/features/costs/domain/price_book.dart';
import 'package:augustyniak_capture/features/costs/presentation/pricing_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));

PricingSection _section({
  Map<String, int> missingRateCounts = const <String, int>{},
  int unknownQuantityCount = 0,
  void Function(String, ModelPrice?)? onRateChanged,
}) {
  return PricingSection(
    thisMonthUsd: 1.24,
    allTimeUsd: 8.90,
    storageBytes: 2254857830,
    storagePrice: StoragePrice.defaults,
    models: const <String>['gpt-transcribe', 'gpt-5.6-luna'],
    priceBook: const PriceBook(),
    missingRateCounts: missingRateCounts,
    unknownQuantityCount: unknownQuantityCount,
    verifiedOn: DateTime.utc(2026, 8, 9),
    onRateChanged: onRateChanged ?? (String _, ModelPrice? _) {},
  );
}

void main() {
  testWidgets('reports the month, the all-time total and the storage rate', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_host(_section()));
    await tester.pump();

    expect(find.textContaining('\$1.24'), findsOneWidget);
    expect(find.textContaining('\$8.90'), findsOneWidget);
    expect(find.textContaining('/mo'), findsOneWidget);
  });

  testWidgets('lists only the models in use', (WidgetTester tester) async {
    await tester.pumpWidget(_host(_section()));
    await tester.pump();

    expect(find.text('gpt-transcribe'), findsOneWidget);
    expect(find.text('claude-opus-5'), findsNothing);
  });

  testWidgets('prints the date the shipped rates were verified', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_host(_section()));
    await tester.pump();

    expect(find.textContaining('2026-08-09'), findsOneWidget);
  });

  testWidgets('MISSING RATES appears only when a rate is missing', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_host(_section()));
    await tester.pump();
    expect(find.text('MISSING RATES'), findsNothing);

    await tester.pumpWidget(
      _host(_section(missingRateCounts: <String, int>{'gpt-6-nova': 3})),
    );
    await tester.pump();

    expect(find.text('MISSING RATES'), findsOneWidget);
    expect(find.textContaining('gpt-6-nova'), findsOneWidget);
    expect(find.textContaining('3'), findsWidgets);
  });

  testWidgets('an unknown-quantity count is reported apart from MISSING RATES', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_host(_section(unknownQuantityCount: 2)));
    await tester.pump();

    // No rate would price these, so they must not appear under the control
    // that offers one.
    expect(find.text('MISSING RATES'), findsNothing);
    expect(find.textContaining('unknown audio duration'), findsOneWidget);
  });

  testWidgets('editing a rate reports the new value', (
    WidgetTester tester,
  ) async {
    final List<String> edits = <String>[];
    await tester.pumpWidget(
      _host(
        _section(
          onRateChanged: (String key, ModelPrice? price) =>
              edits.add('$key:${price?.inputPerMTok}'),
        ),
      ),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField).first, '0.42');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(edits.single, startsWith('gpt-transcribe:'));
  });
}
