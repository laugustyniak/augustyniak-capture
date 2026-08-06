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
      repository = LocalJsonClipboardRepository(
        maxItems: 3,
        storageDirectoryProvider: () async => tempDir,
      );
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
      expect(repository.items.firstWhere((e) => e.id == '1').collections, {
        'Prompty',
      });

      expect(repository.allCollections, {'Prompty'});

      await repository.clearHistory();
      expect(repository.items, isEmpty);
    });

    test(
      'persists items, caps history and ignores adjacent duplicates',
      () async {
        await repository.initialize();
        for (int index = 0; index < 4; index++) {
          await repository.addItem(_textItem('$index', 'Text $index'));
        }
        await repository.addItem(_textItem('duplicate-id', 'Text 3'));

        expect(
          repository.items.map((ClipboardItem item) => item.text),
          <String?>['Text 3', 'Text 2', 'Text 1'],
        );

        final LocalJsonClipboardRepository restored =
            LocalJsonClipboardRepository(
              maxItems: 3,
              storageDirectoryProvider: () async => tempDir,
            );
        await restored.initialize();
        expect(restored.items.map((ClipboardItem item) => item.text), <String?>[
          'Text 3',
          'Text 2',
          'Text 1',
        ]);
      },
    );

    test(
      'deleting or evicting image items removes their owned files',
      () async {
        final File evicted = File('${tempDir.path}/evicted.png')
          ..writeAsBytesSync(<int>[1]);
        final File deleted = File('${tempDir.path}/deleted.png')
          ..writeAsBytesSync(<int>[2]);
        await repository.addItem(_imageItem('image-1', evicted.path));
        await repository.addItem(_textItem('1', 'One'));
        await repository.addItem(_textItem('2', 'Two'));
        await repository.addItem(_imageItem('image-2', deleted.path));

        expect(await evicted.exists(), isFalse);
        expect(await deleted.exists(), isTrue);

        await repository.deleteItem('image-2');
        expect(await deleted.exists(), isFalse);
      },
    );
  });

  group('ClipboardWatcherService & Sheet Widget', () {
    testWidgets('renders empty history sheet', (WidgetTester tester) async {
      final ClipboardRepository repository = _MemoryClipboardRepository();
      await repository.initialize();
      final ClipboardWatcherService service = ClipboardWatcherService(
        repository: repository,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ClipboardHistorySheet(watcherService: service)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('SCHOWEK SYSTEMOWY'), findsOneWidget);
      expect(find.text('Schowek jest pusty'), findsOneWidget);

      service.dispose();
    });

    testWidgets(
      'renders list with items and navigates with arrow keys and enter',
      (WidgetTester tester) async {
        final ClipboardRepository repository = _MemoryClipboardRepository();
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

        final _FakeClipboardGateway gateway = _FakeClipboardGateway();
        final ClipboardWatcherService service = ClipboardWatcherService(
          repository: repository,
          gateway: gateway,
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

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(gateway.copiedText, 'Banana Smoothie');

        service.dispose();
      },
    );

    testWidgets('converts a text clipboard item into a Capture', (
      WidgetTester tester,
    ) async {
      final _MemoryClipboardRepository repository =
          _MemoryClipboardRepository();
      await repository.addItem(_textItem('1', 'Convert me'));
      final ClipboardWatcherService service = ClipboardWatcherService(
        repository: repository,
        gateway: _FakeClipboardGateway(),
      );
      String? convertedText;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ClipboardHistorySheet(
              watcherService: service,
              onConvertText: (String text) async => convertedText = text,
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(
        find.byTooltip('Przekaż do przetworzenia LLM (Capture ✨)'),
      );
      await tester.pump();
      expect(convertedText, 'Convert me');
      service.dispose();
    });

    test(
      'captures new text and image once and copies through the gateway',
      () async {
        final _MemoryClipboardRepository repository =
            _MemoryClipboardRepository();
        final _FakeClipboardGateway gateway = _FakeClipboardGateway(
          text: 'Hello',
          imagePath: null,
        );
        final ClipboardWatcherService service = ClipboardWatcherService(
          repository: repository,
          gateway: gateway,
        );

        await service.checkNow();
        await service.checkNow();
        expect(repository.items, hasLength(1));
        expect(repository.items.single.text, 'Hello');

        gateway
          ..text = null
          ..imagePath = '/tmp/image.png';
        await service.checkNow();
        await service.checkNow();
        expect(repository.items, hasLength(2));
        expect(repository.items.first.type, ClipboardItemType.image);

        await service.copyToClipboard(repository.items.last);
        await service.copyToClipboard(repository.items.first);
        expect(gateway.copiedText, 'Hello');
        expect(gateway.copiedImagePath, '/tmp/image.png');
        service.dispose();
      },
    );

    test('still captures text when native image support is unavailable', () async {
      final _MemoryClipboardRepository repository =
          _MemoryClipboardRepository();
      final _FakeClipboardGateway gateway = _FakeClipboardGateway(
        text: 'Portable text',
        imageReadError: MissingPluginException(),
      );
      final ClipboardWatcherService service = ClipboardWatcherService(
        repository: repository,
        gateway: gateway,
      );

      await service.checkNow();

      expect(repository.items.single.text, 'Portable text');
      service.dispose();
    });
  });
}

ClipboardItem _textItem(String id, String text) => ClipboardItem(
  id: id,
  type: ClipboardItemType.text,
  copiedAt: DateTime.utc(2026, 8, 7),
  text: text,
);

ClipboardItem _imageItem(String id, String path) => ClipboardItem(
  id: id,
  type: ClipboardItemType.image,
  copiedAt: DateTime.utc(2026, 8, 7),
  imagePath: path,
);

class _MemoryClipboardRepository implements ClipboardRepository {
  final List<ClipboardItem> _items = <ClipboardItem>[];

  @override
  List<ClipboardItem> get items => List<ClipboardItem>.unmodifiable(_items);

  @override
  Set<String> get allCollections =>
      _items.expand((ClipboardItem item) => item.collections).toSet();

  @override
  Future<void> addItem(ClipboardItem item) async => _items.insert(0, item);

  @override
  Future<void> clearHistory() async => _items.clear();

  @override
  Future<void> deleteItem(String id) async =>
      _items.removeWhere((ClipboardItem item) => item.id == id);

  @override
  Future<List<ClipboardItem>> getItems() async => items;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> toggleItemCollection(String id, String collectionName) async {
    final int index = _items.indexWhere((ClipboardItem item) => item.id == id);
    if (index < 0) return;
    final ClipboardItem item = _items[index];
    final Set<String> collections = Set<String>.from(item.collections);
    collections.contains(collectionName)
        ? collections.remove(collectionName)
        : collections.add(collectionName);
    _items[index] = item.copyWith(collections: collections);
  }
}

class _FakeClipboardGateway implements ClipboardGateway {
  _FakeClipboardGateway({this.text, this.imagePath, this.imageReadError});

  String? text;
  String? imagePath;
  String? copiedText;
  String? copiedImagePath;
  final Object? imageReadError;

  @override
  Future<void> copyImage(String path) async => copiedImagePath = path;

  @override
  Future<void> copyText(String text) async => copiedText = text;

  @override
  Future<String?> getImagePath() async {
    if (imageReadError != null) throw imageReadError!;
    return imagePath;
  }

  @override
  Future<String?> getText() async => text;
}
