import 'package:flutter_test/flutter_test.dart';
import 'package:voice_notes_phase1/features/logs/data/log_store.dart';
import 'package:voice_notes_phase1/features/logs/domain/log_event.dart';
import 'package:voice_notes_phase1/features/logs/presentation/logs_tab.dart';

import '../support/harness.dart';

/// Guards the log stream before its `ChoiceChip` styling is extracted into a
/// shared widget.
void main() {
  Future<void> pumpLogs(WidgetTester tester, LogStore store) async {
    await tester.pumpWidget(
      hostTab(() => LogsTab(store: store), listenable: store),
    );
    await tester.pump();
  }

  testWidgets('an empty store shows the empty panel', (
    WidgetTester tester,
  ) async {
    await pumpLogs(tester, buildLogStore());

    expect(find.text('Brak zdarzeń.'), findsOneWidget);
    expect(find.text('WYCZYŚĆ LOGI'), findsNothing);
  });

  testWidgets('level chips show per-level counts', (WidgetTester tester) async {
    final LogStore store = buildLogStore();
    store.log('ok');
    store.log('uwaga', level: LogLevel.warn);
    store.log('błąd', level: LogLevel.error);
    await pumpLogs(tester, store);

    expect(find.text('ALL 3'), findsOneWidget);
    expect(find.text('INFO 1'), findsOneWidget);
    expect(find.text('WARN 1'), findsOneWidget);
    expect(find.text('ERROR 1'), findsOneWidget);
  });

  testWidgets('picking a level filters the stream', (
    WidgetTester tester,
  ) async {
    final LogStore store = buildLogStore();
    store.log('zwykłe zdarzenie');
    store.log('coś poszło źle', level: LogLevel.error);
    await pumpLogs(tester, store);

    expect(find.text('zwykłe zdarzenie'), findsOneWidget);

    await tester.tap(find.text('ERROR 1'));
    await tester.pumpAndSettle();

    expect(find.text('coś poszło źle'), findsOneWidget);
    expect(find.text('zwykłe zdarzenie'), findsNothing);
  });

  testWidgets('newest events render first', (WidgetTester tester) async {
    final LogStore store = buildLogStore();
    store.log('pierwsze');
    store.log('drugie');
    await pumpLogs(tester, store);

    final Offset first = tester.getTopLeft(find.text('drugie'));
    final Offset second = tester.getTopLeft(find.text('pierwsze'));
    expect(first.dy, lessThan(second.dy));
  });

  testWidgets('clear asks for confirmation and cancelling keeps the events', (
    WidgetTester tester,
  ) async {
    final LogStore store = buildLogStore();
    store.log('zostaw mnie');
    await pumpLogs(tester, store);

    await tester.tap(find.text('WYCZYŚĆ LOGI'));
    await tester.pumpAndSettle();
    expect(find.text('Wyczyścić logi?'), findsOneWidget);

    await tester.tap(find.text('ANULUJ'));
    await tester.pumpAndSettle();

    expect(store.events, hasLength(1));
    expect(find.text('zostaw mnie'), findsOneWidget);
  });

  testWidgets('confirming clear empties the store', (
    WidgetTester tester,
  ) async {
    final LogStore store = buildLogStore();
    store.log('do usunięcia');
    await pumpLogs(tester, store);

    await tester.tap(find.text('WYCZYŚĆ LOGI'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('WYCZYŚĆ'));
    await tester.pumpAndSettle();

    expect(store.events, isEmpty);
    expect(find.text('Brak zdarzeń.'), findsOneWidget);
  });
}
