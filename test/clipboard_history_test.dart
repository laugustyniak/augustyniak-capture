import 'dart:io';

import 'package:augustyniak_capture/features/clipboard/data/clipboard_repository.dart';
import 'package:augustyniak_capture/features/clipboard/domain/clipboard_item.dart';
import 'package:augustyniak_capture/features/clipboard/domain/clipboard_watcher_service.dart';
import 'package:augustyniak_capture/features/clipboard/presentation/clipboard_history_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ClipboardItem', () {
    test('serialization roundtrip with collections', () {
      final ClipboardItem item = ClipboardItem(
        id: 'test-1',
        type: ClipboardItemType.text,
        copiedAt: DateTime.parse('2026-08-06T20:00:00.000Z'),
        text: 'Hello world',
        preview: 'Hello...',
        collections: {'Kod', 'Ulubione'},
      );

      final Map<String, dynamic> json = item.toJson();
      final ClipboardItem restored = ClipboardItem.fromJson(json);

      expect(restored.id, item.id);
      expect(restored.type, item.type);
      expect(restored.text, item.text);
      expect(restored.collections, {'Kod', 'Ulubione'});
      expect(restored, item);
    });
  });

  group('ClipboardRepository', () {
    late Directory tempDir;
    late ClipboardRepository repository;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('clipboard_test_');
      repository = ClipboardRepository(maxItems: 3);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('add, toggle collections and clear items', () async {
      await repository.initialize();
      expect(repository.items, isEmpty);

      final ClipboardItem item1 = ClipboardItem(
        id: '1',
        type: ClipboardItemType.text,
        copiedAt: DateTime.now(),
        text: 'First',
      );
      final ClipboardItem item2 = ClipboardItem(
        id: '2',
        type: ClipboardItemType.text,
        copiedAt: DateTime.now(),
        text: 'Second',
      );

      await repository.addItem(item1);
      await repository.addItem(item2);

      await repository.toggleItemCollection('1', 'Prompty');
      expect(repository.items.firstWhere((e) => e.id == '1').collections, {'Prompty'});

      expect(repository.allCollections, {'Prompty'});

      await repository.clearHistory();
      expect(repository.items, isEmpty);
    });
  });

  group('ClipboardWatcherService & Sheet Widget', () {
    testWidgets('renders empty history sheet', (WidgetTester tester) async {
      final ClipboardRepository repository = ClipboardRepository();
      await repository.initialize();
      final ClipboardWatcherService service = ClipboardWatcherService(
        repository: repository,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ClipboardHistorySheet(watcherService: service),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('SCHOWEK SYSTEMOWY'), findsOneWidget);
      expect(find.text('Schowek jest pusty'), findsOneWidget);

      service.dispose();
    });

    testWidgets('renders list with items and navigates with arrow keys and enter', (WidgetTester tester) async {
      final ClipboardRepository repository = ClipboardRepository();
      await repository.initialize();
      await repository.addItem(
        ClipboardItem(
          id: '1',
          type: ClipboardItemType.text,
          copiedAt: DateTime.now(),
          text: 'Apple Pie Recipe',
        ),
      );
      await repository.addItem(
        ClipboardItem(
          id: '2',
          type: ClipboardItemType.text,
          copiedAt: DateTime.now(),
          text: 'Banana Smoothie',
        ),
      );

      final ClipboardWatcherService service = ClipboardWatcherService(
        repository: repository,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ClipboardHistorySheet(watcherService: service),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Apple Pie Recipe'), findsOneWidget);
      expect(find.text('Banana Smoothie'), findsOneWidget);

      // Press Arrow Down to navigate selection
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump(const Duration(milliseconds: 100));

      // Press Arrow Up to navigate back
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump(const Duration(milliseconds: 100));

      // Filter text
      await tester.enterText(find.byType(TextField).first, 'Banana');
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Apple Pie Recipe'), findsNothing);
      expect(find.text('Banana Smoothie'), findsOneWidget);

      service.dispose();
    });
  });
}
