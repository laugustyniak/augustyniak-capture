import 'package:augustyniak_capture/features/costs/domain/model_price.dart';
import 'package:augustyniak_capture/features/costs/domain/price_book.dart';
import 'package:augustyniak_capture/features/costs/presentation/pricing_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));

PricingSection _section({
  List<String> models = const <String>['gpt-transcribe', 'gpt-5.6-luna'],
  Map<String, int> missingRateCounts = const <String, int>{},
  int unknownQuantityCount = 0,
  void Function(String, ModelPrice?)? onRateChanged,
}) {
  return PricingSection(
    thisMonthUsd: 1.24,
    allTimeUsd: 8.90,
    storageBytes: 2254857830,
    storagePrice: StoragePrice.defaults,
    models: models,
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

  testWidgets(
    'a model that is both in use and missing a rate renders exactly one '
    'editable form',
    (WidgetTester tester) async {
      // `missingRateCounts` only ever contains a model that also produced a
      // usage event — which is exactly what puts it in `models` too — so the
      // two lists overlap in real usage. A model with no rate must still show
      // up only once, not once in the primary table and again (with the same
      // `TextEditingController`s aliased into two places) under MISSING
      // RATES.
      await tester.pumpWidget(
        _host(
          _section(
            models: const <String>['gpt-6-nova'],
            missingRateCounts: <String, int>{'gpt-6-nova': 3},
          ),
        ),
      );
      await tester.pump();

      // The primary row's label is the bare key; the MISSING RATES row's
      // label is `key · N call(s)`. If the model rendered twice, this would
      // find two widgets — the primary label plus the missing-rates line.
      expect(find.textContaining('gpt-6-nova'), findsOneWidget);

      // `gpt-6-nova` has no known rate, so its one form is chat-shaped: an
      // input and an output field — 2 `TextField`s. Rendered twice (once in
      // the primary table, once under MISSING RATES, each pointing at the
      // same `TextEditingController`s) this would report 4: a second,
      // independent signal from the label count above rather than the same
      // check twice.
      expect(find.byType(TextField), findsNWidgets(2));
    },
  );

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
