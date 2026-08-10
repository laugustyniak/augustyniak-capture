import 'package:augustyniak_capture/features/costs/domain/model_price.dart';
import 'package:augustyniak_capture/features/costs/domain/price_book.dart';
import 'package:augustyniak_capture/features/costs/domain/usage_event.dart';
import 'package:augustyniak_capture/features/costs/presentation/pricing_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));

PricingSection _section({
  List<String> models = const <String>['gpt-transcribe', 'gpt-5.6-luna'],
  Map<String, MissingRateInfo> missingRateCounts = const <String, MissingRateInfo>{},
  int unknownQuantityCount = 0,
  UsageTotal thisMonth = const UsageTotal(amountUsd: 1.24, unpricedCount: 0),
  UsageTotal allTime = const UsageTotal(amountUsd: 8.90, unpricedCount: 0),
  void Function(String, ModelPrice?)? onRateChanged,
}) {
  return PricingSection(
    thisMonth: thisMonth,
    allTime: allTime,
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
      _host(_section(missingRateCounts: <String, MissingRateInfo>{
        'gpt-6-nova': const MissingRateInfo(count: 3, isTranscription: false),
      })),
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
            missingRateCounts: <String, MissingRateInfo>{
              'gpt-6-nova':
                  const MissingRateInfo(count: 3, isTranscription: false),
            },
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

  testWidgets(
    'a value typed and then blurred, without submitting, is still committed',
    (WidgetTester tester) async {
      final List<String> edits = <String>[];
      await tester.pumpWidget(
        _host(
          _section(
            onRateChanged: (String key, ModelPrice? price) => edits.add(
              '$key:${price?.perAudioMinute ?? price?.inputPerMTok}',
            ),
          ),
        ),
      );
      await tester.pump();

      // Field 0 is gpt-transcribe's single audio-minute field; field 1 is
      // gpt-5.6-luna's input field. Moving focus there with a tap — never
      // submitting field 0 — is what a mouse user actually does when leaving
      // a field, and is exactly what `onSubmitted` alone cannot see.
      await tester.enterText(find.byType(TextField).at(0), '0.05');
      await tester.pump();
      await tester.tap(find.byType(TextField).at(1));
      await tester.pump();

      expect(edits, contains('gpt-transcribe:0.05'));
    },
  );

  testWidgets(
    'a missing-rate key used for transcription renders the audio-minute '
    'field, not the chat pair, and a rate typed there prices it',
    (WidgetTester tester) async {
      final List<ModelPrice?> committed = <ModelPrice?>[];
      await tester.pumpWidget(
        _host(
          _section(
            models: const <String>[],
            missingRateCounts: <String, MissingRateInfo>{
              'custom-whisper':
                  const MissingRateInfo(count: 2, isTranscription: true),
            },
            onRateChanged: (String key, ModelPrice? price) =>
                committed.add(price),
          ),
        ),
      );
      await tester.pump();

      // Before I3, a missing-rate key always rendered the chat pair (2
      // fields) because the shape was read off `existing`, which is null for
      // exactly the keys under MISSING RATES.
      expect(find.byType(TextField), findsNWidgets(1));

      await tester.enterText(find.byType(TextField).first, '0.02');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(committed.single?.perAudioMinute, closeTo(0.02, 1e-9));
      expect(committed.single?.inputPerMTok, isNull);
    },
  );

  testWidgets(
    'THIS MONTH reports a mixed total with the unpriced calls it excludes',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          _section(
            thisMonth:
                const UsageTotal(amountUsd: 1.24, unpricedCount: 3),
          ),
        ),
      );
      await tester.pump();

      expect(find.textContaining('\$1.24'), findsOneWidget);
      expect(find.textContaining('3 unpriced'), findsOneWidget);
    },
  );

  testWidgets(
    'an all-unpriced ALL TIME total never renders a bare \$0.0000',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          _section(
            allTime: const UsageTotal(amountUsd: null, unpricedCount: 5),
          ),
        ),
      );
      await tester.pump();

      expect(find.textContaining('\$0.0000'), findsNothing);
      expect(find.textContaining('5 unpriced'), findsOneWidget);
    },
  );

  testWidgets(
    'an empty history (no usage events at all) renders an em dash, never '
    '\$0.0000',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          _section(
            thisMonth: const UsageTotal(amountUsd: null, unpricedCount: 0),
            allTime: const UsageTotal(amountUsd: null, unpricedCount: 0),
          ),
        ),
      );
      await tester.pump();

      expect(find.textContaining('\$0.0000'), findsNothing);
      expect(find.text('—'), findsNWidgets(2));
    },
  );

  testWidgets(
    'a genuinely zero-priced history (every event priced, summing to '
    'exactly zero) still renders \$0.0000',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          _section(
            thisMonth: const UsageTotal(amountUsd: 0.0, unpricedCount: 0),
            allTime: const UsageTotal(amountUsd: 0.0, unpricedCount: 0),
          ),
        ),
      );
      await tester.pump();

      expect(find.textContaining('\$0.0000'), findsNWidgets(2));
      expect(find.text('—'), findsNothing);
    },
  );
}
