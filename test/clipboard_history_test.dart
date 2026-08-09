import 'dart:async';
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
        collections: {'Snippets', 'Favourites'},
      );

      final Map<String, dynamic> json = item.toJson();
      final ClipboardItem restored = ClipboardItem.fromJson(json);

      expect(restored.id, item.id);
      expect(restored.type, item.type);
      expect(restored.text, item.text);
      expect(restored.collections, {'Snippets', 'Favourites'});
      expect(restored, item);
    });

    test('previewFor shortens long text and passes short text through', () {
      expect(ClipboardItem.previewFor('short text'), 'short text');

      final String exactly120 = 'x' * 120;
      expect(ClipboardItem.previewFor(exactly120), exactly120);

      final String tooLong = 'y' * 121;
      expect(ClipboardItem.previewFor(tooLong), '${'y' * 120}...');
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

      await repository.toggleItemCollection('1', 'Prompts');
      expect(repository.items.firstWhere((e) => e.id == '1').collections, {
        'Prompts',
      });

      expect(repository.allCollections, {'Prompts'});

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

    test('preserves an unreadable history before starting empty', () async {
      final File index = File('${tempDir.path}/clipboard_history.json');
      await index.writeAsString('{not-json');

      await repository.initialize();

      expect(repository.items, isEmpty);
      expect(
        tempDir.listSync().whereType<File>().where(
          (File file) => file.path.contains('.corrupt-'),
        ),
        hasLength(1),
      );
    });

    test('editing text rewrites preview and keeps position and collections',
        () async {
      await repository.initialize();
      await repository.addItem(_textItem('1', 'First'));
      await repository.addItem(_textItem('2', 'Second'));
      await repository.toggleItemCollection('2', 'Code');

      final DateTime originalCopiedAt = repository.items
          .firstWhere((ClipboardItem item) => item.id == '2')
          .copiedAt;

      await repository.updateItemText('2', 'Second, corrected');

      // '2' was the newest entry, so it stays at index 0.
      expect(repository.items.map((ClipboardItem item) => item.id),
          <String>['2', '1']);

      final ClipboardItem edited = repository.items.first;
      expect(edited.text, 'Second, corrected');
      expect(edited.preview, 'Second, corrected');
      expect(edited.collections, <String>{'Code'});
      expect(edited.copiedAt, originalCopiedAt);
    });

    test('editing recomputes preview for long text', () async {
      await repository.initialize();
      await repository.addItem(_textItem('1', 'short'));

      final String long = 'z' * 200;
      await repository.updateItemText('1', long);

      expect(repository.items.single.text, long);
      expect(repository.items.single.preview, '${'z' * 120}...');
    });

    test('blank text leaves the item untouched', () async {
      await repository.initialize();
      await repository.addItem(_textItem('1', 'Original'));

      await repository.updateItemText('1', '');
      expect(repository.items.single.text, 'Original');

      await repository.updateItemText('1', '   \n  ');
      expect(repository.items.single.text, 'Original');
    });

    test('an image entry is never rewritten', () async {
      await repository.initialize();
      await repository.addItem(_imageItem('img', '${tempDir.path}/a.png'));

      await repository.updateItemText('img', 'this must not get in');

      expect(repository.items.single.text, isNull);
    });

    test('an unknown id is a silent no-op', () async {
      await repository.initialize();
      await repository.addItem(_textItem('1', 'Text'));

      await repository.updateItemText('no-such-id', 'anything');

      expect(repository.items, hasLength(1));
      expect(repository.items.single.text, 'Text');
    });

    test('an edit survives reloading the repository from disk', () async {
      await repository.initialize();
      await repository.addItem(_textItem('1', 'Before'));
      await repository.updateItemText('1', 'After');

      final LocalJsonClipboardRepository restored = LocalJsonClipboardRepository(
        maxItems: 3,
        storageDirectoryProvider: () async => tempDir,
      );
      await restored.initialize();

      expect(restored.items.single.text, 'After');
    });
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

      expect(find.text('CLIPBOARD'), findsOneWidget);
      expect(find.text('The clipboard history is empty.'), findsOneWidget);
      // The preview pane says what the sheet is for rather than sitting blank
      // beside an empty list.
      expect(find.text('Nothing copied yet.'), findsOneWidget);

      service.dispose();
    });

    testWidgets(
      'the preview follows the selection, and Enter pastes what it shows',
      (WidgetTester tester) async {
        final ClipboardRepository repository = _MemoryClipboardRepository();
        await repository.initialize();
        // Inserted at the head, so the newest entry — Banana — is first.
        await repository.addItem(_textItem('1', 'Apple Pie Recipe'));
        await repository.addItem(_textItem('2', 'Banana Smoothie'));

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

        Finder inPreview(String value) => find.descendant(
          of: find.byKey(ClipboardHistorySheet.previewKey),
          matching: find.text(value),
        );
        Finder inList(String value) => find.descendant(
          of: find.byKey(ClipboardHistorySheet.listKey),
          matching: find.text(value),
        );

        // Both rows are in the list; the newest is what the pane opens on, so
        // the sheet is never a blank half-screen.
        expect(inList('Apple Pie Recipe'), findsOneWidget);
        expect(inList('Banana Smoothie'), findsOneWidget);
        expect(inPreview('Banana Smoothie'), findsWidgets);
        expect(inPreview('Apple Pie Recipe'), findsNothing);

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump(const Duration(milliseconds: 200));
        expect(inPreview('Apple Pie Recipe'), findsWidgets);
        expect(inPreview('Banana Smoothie'), findsNothing);

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump(const Duration(milliseconds: 200));
        expect(inPreview('Banana Smoothie'), findsWidgets);

        // The selection is an id, not an index, and this is what separates the
        // two: a new entry lands at the head of the list, so index 0 now points
        // at a different capture while the id still resolves to Banana.
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump(const Duration(milliseconds: 200));
        gateway.text = 'Cherry Tart';
        await service.checkNow();
        await tester.pump(const Duration(milliseconds: 100));

        expect(inList('Cherry Tart'), findsOneWidget);
        expect(inPreview('Apple Pie Recipe'), findsWidgets);
        expect(inPreview('Cherry Tart'), findsNothing);

        await tester.enterText(find.byType(TextField).first, 'Apple');
        await tester.pump(const Duration(milliseconds: 100));

        expect(inList('Banana Smoothie'), findsNothing);
        expect(inPreview('Apple Pie Recipe'), findsWidgets);

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(gateway.copiedText, 'Apple Pie Recipe');

        service.dispose();
      },
    );

    testWidgets('the list rows carry no destructive control', (
      WidgetTester tester,
    ) async {
      // The old row put convert / collect / delete about 20 px from the tap
      // target that pastes and closes the sheet. Deleting a clipboard entry
      // cannot be undone, so it belongs in the pane, behind a selection.
      final ClipboardRepository repository = _MemoryClipboardRepository();
      await repository.addItem(_textItem('1', 'Only entry'));
      final ClipboardWatcherService service = ClipboardWatcherService(
        repository: repository,
        gateway: _FakeClipboardGateway(),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ClipboardHistorySheet(watcherService: service)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        find.descendant(
          of: find.byKey(ClipboardHistorySheet.listKey),
          matching: find.byIcon(Icons.delete_outline_rounded),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byKey(ClipboardHistorySheet.previewKey),
          matching: find.text('DELETE'),
        ),
        findsOneWidget,
      );

      service.dispose();
    });

    testWidgets('the tab form does not autofocus its search box', (
      WidgetTester tester,
    ) async {
      // The shell keeps all six tabs alive in an IndexedStack, so this widget
      // is built at start-up even when the Queue is on screen. Autofocusing
      // here took the route's focus and left every queue shortcut dead until
      // the user clicked something.
      final ClipboardRepository repository = _MemoryClipboardRepository();
      await repository.addItem(_textItem('1', 'Only entry'));
      final ClipboardWatcherService service = ClipboardWatcherService(
        repository: repository,
        gateway: _FakeClipboardGateway(),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ClipboardHistorySheet(
              watcherService: service,
              isModal: false,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        tester.widget<TextField>(find.byType(TextField).first).autofocus,
        isFalse,
      );
      expect(
        tester.widget<EditableText>(find.byType(EditableText).first).focusNode
            .hasFocus,
        isFalse,
      );

      service.dispose();
    });

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

      // The action lives in the preview pane now, not on the row: the row's
      // only job is to be readable and selectable.
      await tester.tap(find.text('TO CAPTURE'));
      await tester.pump();
      expect(convertedText, 'Convert me');
      service.dispose();
    });

    test('pasting on a platform with no autoPaste handler stays quiet', () async {
      // Android, iOS and Linux register no handler for this channel, so
      // `invokeMethod` answers MissingPluginException. Awaiting it is what puts
      // that error inside the method's own `try`; unawaited it escapes as an
      // unhandled async error, which is what this zone catches.
      //
      // The zone is the assertion, not decoration. A plain `await
      // pasteToActiveApp()` passes either way: an orphaned future reports
      // itself too late for the test that created it, so the failure lands on
      // whichever test happens to be running — or on none at all.
      final ClipboardWatcherService service = ClipboardWatcherService(
        repository: _MemoryClipboardRepository(),
        gateway: _FakeClipboardGateway(),
      );

      Object? escaped;
      await runZonedGuarded(() async {
        await service.pasteToActiveApp();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }, (Object error, StackTrace stack) => escaped = error);

      expect(escaped, isNull);
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

    test(
      'still captures text when native image support is unavailable',
      () async {
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
      },
    );

    test('editing an item notifies listeners and never touches the clipboard',
        () async {
      final _MemoryClipboardRepository repository = _MemoryClipboardRepository();
      final _FakeClipboardGateway gateway = _FakeClipboardGateway(
        text: 'Before',
      );
      final ClipboardWatcherService service = ClipboardWatcherService(
        repository: repository,
        gateway: gateway,
      );

      // Prime the watcher's last-seen clipboard text to 'Before', the same
      // way a real capture would have set it before the item was ever edited.
      await service.checkNow();
      final String id = repository.items.single.id;

      int notifications = 0;
      service.addListener(() => notifications++);

      await service.updateItemText(id, 'After');

      expect(repository.items.single.text, 'After');
      expect(notifications, 1);
      // Saving an edit must not replace what the user currently has copied.
      expect(gateway.copiedText, isNull);
      expect(gateway.copiedImagePath, isNull);

      // The system clipboard still holds the pre-edit text. If the edit had
      // also updated the watcher's last-seen text, this poll would see the
      // old text as "new" and capture a spurious duplicate entry.
      await service.checkNow();
      expect(repository.items.length, 1);

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

  @override
  Future<void> updateItemText(String id, String text) async {
    if (text.trim().isEmpty) return;
    final int index = _items.indexWhere((ClipboardItem item) => item.id == id);
    if (index < 0) return;
    final ClipboardItem current = _items[index];
    if (current.type != ClipboardItemType.text) return;
    _items[index] = current.copyWith(
      text: text,
      preview: ClipboardItem.previewFor(text),
    );
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
