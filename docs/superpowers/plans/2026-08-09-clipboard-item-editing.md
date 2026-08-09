# Edycja wpisów w historii schowka — plan wdrożenia

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Akcja `EDIT` w panelu podglądu historii schowka zamienia treść wpisu na pole tekstowe w tym samym miejscu; zmiana zapisuje się przy utracie fokusu i nadpisuje wpis, nie zmieniając jego pozycji na liście.

**Architecture:** Nowa metoda `updateItemText` w interfejsie `ClipboardRepository` (dwie implementacje: plikowa i SQLite) przechodzi przez cienkie `ClipboardWatcherService.updateItemText` do arkusza. Stan edycji — `_editingId`, `_editController`, `_syncedText` — mieszka w `_ClipboardHistorySheetState`, nie w podglądzie, bo zmiana zaznaczenia musi umieć wymusić zapis. `_ClipboardPreview` zostaje bezstanowy i dostaje kontroler z góry. `copiedAt` nigdy się nie zmienia, więc poprawiony wpis zostaje na swojej pozycji.

**Tech Stack:** Flutter / Dart 3.10, `sqlite3`, `flutter_test`. Bez nowych zależności.

**Spec:** `docs/superpowers/specs/2026-08-09-clipboard-item-editing-design.md`

## Stan wyjściowy

Plan pisany przeciwko arkuszowi po przebudowie z commita `cf78b7f` („Rebuild the
clipboard history as a list beside a preview"). Kotwice w kodzie:

| Symbol | Linia | Rola |
| --- | --- | --- |
| `_ClipboardHistorySheetState` | 73 | stan arkusza; `_selectedId` (96), `_handoffNotice` (100) |
| `_move` | 145 | strzałki przesuwają zaznaczenie |
| `_handleKey` | 177 | strzałki i `Enter` |
| `_manageCollections` | 330 | akcja `COLLECTIONS`, zapisuje natychmiast |
| `itemBuilder` → `_ClipboardListRow.onTap` | 520–531 | klik w wiersz ustawia `_selectedId` |
| `_buildPreview` | 535 | składa `_ClipboardPreview` |
| `_ClipboardPreview` | 834 | bezstanowy; ramka treści 914–953, stopka akcji 968–996 |
| `_PreviewAction` | 1006 | `label`, `onPressed`, `icon`, `color`, `primary` |

Poprzednia wersja tego planu celowała w `_ClipboardItemTile` i zależała od
Taska 2 planu `2026-08-09-english-only-strings`. **Obie te rzeczy są
nieaktualne**: klasa nie istnieje, a arkusz jest już po angielsku.

## Global Constraints

- **Wszystkie napisy i komentarze w kodzie po angielsku.** CLAUDE.md: *„user-facing strings in code are English — do not reintroduce Polish"*, i to samo dotyczy identyfikatorów oraz komentarzy.
- **Żaden widget malujący paletę `Console` nie może być konstruowany z `const`.** `test/theme_test.dart:302` skanuje `lib/` regexem `const _Widget(` i zgłosi takie miejsce jako błąd. Deklaracja konstruktora jako `const` jest dozwolona; zakazane jest `const` w miejscu wywołania.
- **Nigdy `tester.pumpAndSettle()` na ekranie ze skupionym `TextField`** — migający kursor to animacja bez końca, więc „brak zaplanowanych klatek" nigdy nie nastąpi i test wisi do timeoutu. Używamy `tester.pump(const Duration(milliseconds: N))`.
- **`copiedAt` nie zmienia się nigdy** przy edycji — to mechanizm realizujący „nadpisz w miejscu".
- **Nie ma CI.** `flutter analyze && flutter test` lokalnie jest twardą bramką.
- Wszystkie testy trafiają do `test/clipboard_history_test.dart`. Plik `test/clipboard_test.dart` mimo nazwy dotyczy `ClipboardSink` w potoku nagrań i nie jest tu ruszany.

## Struktura plików

| Plik | Rola po zmianie |
| --- | --- |
| `lib/features/clipboard/domain/clipboard_item.dart` | + `static String previewFor(String)` |
| `lib/features/clipboard/domain/clipboard_watcher_service.dart` | korzysta z `previewFor`; + `updateItemText` |
| `lib/features/clipboard/data/clipboard_repository.dart` | + `updateItemText` w interfejsie i w implementacji plikowej |
| `lib/features/clipboard/data/sqlite_clipboard_repository.dart` | + `updateItemText` na `UPDATE ... WHERE id = ?` |
| `lib/features/clipboard/presentation/clipboard_history_sheet.dart` | stan edycji w arkuszu, akcja `EDIT`, pole w ramce treści, znacznik `UNSAVED` |
| `test/clipboard_history_test.dart` | + testy repozytorium, serwisu i edycji; fake dostaje `updateItemText` |

---

### Task 1: `ClipboardItem.previewFor` — jedna definicja podglądu

**Files:**
- Modify: `lib/features/clipboard/domain/clipboard_item.dart`
- Modify: `lib/features/clipboard/domain/clipboard_watcher_service.dart` (linia z `preview:` w `checkNow`)
- Test: `test/clipboard_history_test.dart` (grupa `ClipboardItem`)

**Interfaces:**
- Consumes: nic
- Produces: `static String ClipboardItem.previewFor(String text)`; `static const int ClipboardItem.previewLength = 120`

- [ ] **Step 1: Write the failing test**

W `test/clipboard_history_test.dart`, wewnątrz `group('ClipboardItem', ...)`:

```dart
    test('previewFor shortens long text and passes short text through', () {
      expect(ClipboardItem.previewFor('short text'), 'short text');

      final String exactly120 = 'x' * 120;
      expect(ClipboardItem.previewFor(exactly120), exactly120);

      final String tooLong = 'y' * 121;
      expect(ClipboardItem.previewFor(tooLong), '${'y' * 120}...');
    });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/clipboard_history_test.dart --plain-name "previewFor shortens long text"`
Expected: FAIL — `The method 'previewFor' isn't defined for the type 'ClipboardItem'`.

- [ ] **Step 3: Write minimal implementation**

W `lib/features/clipboard/domain/clipboard_item.dart`, w klasie `ClipboardItem`, nad `Map<String, dynamic> toJson()`:

```dart
  /// The shortened body rendered on a history row.
  ///
  /// One definition on purpose: both the watcher storing a fresh entry and the
  /// editor overwriting an existing one compute it from here. Two copies would
  /// drift the first time the limit changes.
  static const int previewLength = 120;

  static String previewFor(String text) => text.length > previewLength
      ? '${text.substring(0, previewLength)}...'
      : text;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/clipboard_history_test.dart --plain-name "previewFor shortens long text"`
Expected: PASS

- [ ] **Step 5: Point the watcher at the shared function**

W `clipboard_watcher_service.dart`, w `checkNow()`, zamień:

```dart
          preview: text.length > 120 ? '${text.substring(0, 120)}...' : text,
```

na:

```dart
          preview: ClipboardItem.previewFor(text),
```

- [ ] **Step 6: Run the clipboard suite**

Run: `flutter test test/clipboard_history_test.dart`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add lib/features/clipboard/domain/clipboard_item.dart \
        lib/features/clipboard/domain/clipboard_watcher_service.dart \
        test/clipboard_history_test.dart
git commit -m "Extract the clipboard preview rule into ClipboardItem.previewFor"
```

---

### Task 2: `updateItemText` w interfejsie i w repozytorium plikowym

**Files:**
- Modify: `lib/features/clipboard/data/clipboard_repository.dart`
- Modify: `lib/features/clipboard/data/sqlite_clipboard_repository.dart` (rusztowanie, Step 5)
- Modify: `test/clipboard_history_test.dart` (fake `_MemoryClipboardRepository`)
- Test: `test/clipboard_history_test.dart` (grupa `ClipboardRepository`)

**Interfaces:**
- Consumes: `ClipboardItem.previewFor(String)` z Task 1
- Produces: `Future<void> ClipboardRepository.updateItemText(String id, String text)` — `copiedAt` nietknięte; pusty/biały tekst ignorowany; wpis `image` ignorowany; nieznane `id` to no-op

**Uwaga o kolejności:** dodanie metody do interfejsu psuje kompilację
`SqliteClipboardRepository` i fake'a `_MemoryClipboardRepository`. Fake
naprawiamy tutaj (Step 4); SQLite dostaje tymczasowy `UnimplementedError`
(Step 5), który Task 3 zastępuje. Dart nie pozwala zostawić klasy bez
implementacji metody interfejsu, więc rusztowanie jest tu konieczne.

- [ ] **Step 1: Write the failing tests**

W `test/clipboard_history_test.dart`, wewnątrz `group('ClipboardRepository', ...)`:

```dart
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/clipboard_history_test.dart`
Expected: FAIL — `The method 'updateItemText' isn't defined for the type 'ClipboardRepository'`.

- [ ] **Step 3: Add the method to the interface and the file-backed implementation**

W `clipboard_repository.dart`, do `abstract class ClipboardRepository`, między `addItem` a `toggleItemCollection`:

```dart
  /// Overwrites an entry's text in place.
  ///
  /// `copiedAt` never changes, so a correction does not push the entry back to
  /// the top of the list. Blank text and image entries are ignored.
  Future<void> updateItemText(String id, String text);
```

Do `LocalJsonClipboardRepository`, po `addItem`:

```dart
  @override
  Future<void> updateItemText(String id, String text) async {
    if (!_initialized) await initialize();
    if (text.trim().isEmpty) return;

    final int index = _items.indexWhere((ClipboardItem item) => item.id == id);
    if (index == -1) return;

    final ClipboardItem current = _items[index];
    if (current.type != ClipboardItemType.text) return;

    _items[index] = current.copyWith(
      text: text,
      preview: ClipboardItem.previewFor(text),
    );
    await _save();
  }
```

- [ ] **Step 4: Teach the test fake the new method**

W `test/clipboard_history_test.dart`, w `_MemoryClipboardRepository`, po `toggleItemCollection`:

```dart
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
```

- [ ] **Step 5: Add a temporary SQLite implementation so the tree compiles**

W `sqlite_clipboard_repository.dart`, po `addItem`:

```dart
  @override
  Future<void> updateItemText(String id, String text) async {
    throw UnimplementedError('Task 3 of this plan supplies the real body.');
  }
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `flutter test test/clipboard_history_test.dart`
Expected: PASS — wszystkie, łącznie z sześcioma nowymi.

- [ ] **Step 7: Commit**

```bash
git add lib/features/clipboard/data/clipboard_repository.dart \
        lib/features/clipboard/data/sqlite_clipboard_repository.dart \
        test/clipboard_history_test.dart
git commit -m "Add ClipboardRepository.updateItemText and its file-backed implementation"
```

---

### Task 3: `updateItemText` w repozytorium SQLite

Implementacja używana w produkcji (`recordings_page.dart` konstruuje
`SqliteClipboardRepository`). Nie da się jej pokryć testem w tym repozytorium —
wymaga `AppDatabase.getInstance()`, a żaden istniejący test tego nie robi.
Weryfikacją jest `flutter analyze`, symetria z przetestowaną wersją plikową i
ręczne uruchomienie z Task 5.

**Files:**
- Modify: `lib/features/clipboard/data/sqlite_clipboard_repository.dart`

**Interfaces:**
- Consumes: `ClipboardItem.previewFor` z Task 1; sygnatura z Task 2
- Produces: nic nowego

- [ ] **Step 1: Replace the temporary implementation**

```dart
  @override
  Future<void> updateItemText(String id, String text) async {
    final AppDatabase db = _appDatabase ?? await AppDatabase.getInstance();
    if (text.trim().isEmpty) return;

    final int index = _items.indexWhere((ClipboardItem item) => item.id == id);
    if (index == -1) return;
    if (_items[index].type != ClipboardItemType.text) return;

    // copied_at is deliberately untouched: getItems() reads
    // ORDER BY copied_at DESC, so the entry keeps its place in the list.
    db.rawDb.execute(
      'UPDATE clipboard_items SET text = ?, preview = ? WHERE id = ?;',
      <Object?>[text, ClipboardItem.previewFor(text), id],
    );

    await getItems();
  }
```

- [ ] **Step 2: Verify the tree analyzes clean**

Run: `flutter analyze`
Expected: brak błędów w plikach tego planu.

- [ ] **Step 3: Run the whole suite**

Run: `flutter test`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add lib/features/clipboard/data/sqlite_clipboard_repository.dart
git commit -m "Implement updateItemText in the SQLite clipboard repository"
```

---

### Task 4: `ClipboardWatcherService.updateItemText`

**Files:**
- Modify: `lib/features/clipboard/domain/clipboard_watcher_service.dart`
- Test: `test/clipboard_history_test.dart`

**Interfaces:**
- Consumes: `ClipboardRepository.updateItemText` z Task 2
- Produces: `Future<void> ClipboardWatcherService.updateItemText(String id, String text)`

- [ ] **Step 1: Write the failing test**

```dart
    test('editing an item notifies listeners and never touches the clipboard',
        () async {
      final _MemoryClipboardRepository repository = _MemoryClipboardRepository();
      await repository.addItem(_textItem('1', 'Before'));
      final _FakeClipboardGateway gateway = _FakeClipboardGateway();
      final ClipboardWatcherService service = ClipboardWatcherService(
        repository: repository,
        gateway: gateway,
      );

      int notifications = 0;
      service.addListener(() => notifications++);

      await service.updateItemText('1', 'After');

      expect(repository.items.single.text, 'After');
      expect(notifications, 1);
      // Saving an edit must not replace what the user currently has copied.
      expect(gateway.copiedText, isNull);
      expect(gateway.copiedImagePath, isNull);

      service.dispose();
    });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/clipboard_history_test.dart --plain-name "editing an item notifies listeners"`
Expected: FAIL — `The method 'updateItemText' isn't defined for the type 'ClipboardWatcherService'`.

- [ ] **Step 3: Write minimal implementation**

W `clipboard_watcher_service.dart`, po `toggleItemCollection`:

```dart
  /// Overwrites an entry's text in place.
  ///
  /// Deliberately leaves `_lastText` and `_lastImagePath` alone: an edit never
  /// writes to the system clipboard, so the next poll sees nothing new and no
  /// duplicate of our own edit is captured.
  Future<void> updateItemText(String id, String text) async {
    await _repository.updateItemText(id, text);
    notifyListeners();
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/clipboard_history_test.dart --plain-name "editing an item notifies listeners"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/features/clipboard/domain/clipboard_watcher_service.dart \
        test/clipboard_history_test.dart
git commit -m "Add ClipboardWatcherService.updateItemText"
```

---

### Task 5: Edycja w miejscu w panelu podglądu

Jedyne zadanie z widoczną zmianą. Kończy się ręcznym uruchomieniem aplikacji —
dla zmiany wizualnej zielony zestaw testów opisuje tylko to, o co go zapytano.

**Files:**
- Modify: `lib/features/clipboard/presentation/clipboard_history_sheet.dart`
- Test: `test/clipboard_history_test.dart`

**Interfaces:**
- Consumes: `ClipboardWatcherService.updateItemText` z Task 4
- Produces: w `_ClipboardHistorySheetState` — `_editingId`, `_editController`, `_syncedText`, `_startEdit`, `_commitEdit`, `_endEdit`, `_revertEdit`, `_isEditDirty`; w `_ClipboardPreview` — nowe pola `editing`, `editController`, `dirty`, `onEdit`, `onEndEdit`, `onRevert`, `onEditFocusLost`

- [ ] **Step 1: Write the failing tests**

W `test/clipboard_history_test.dart`, w grupie widgetowej:

```dart
    /// Builds the sheet over an already-populated repository.
    ///
    /// Every entry must be added **before** this call: the in-memory fake does
    /// not notify, so an entry added afterwards never reaches the list.
    Future<ClipboardWatcherService> pumpSheet(
      WidgetTester tester,
      _MemoryClipboardRepository repository,
    ) async {
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
      return service;
    }

    testWidgets('EDIT is offered for text and withheld for images', (
      WidgetTester tester,
    ) async {
      final _MemoryClipboardRepository repository = _MemoryClipboardRepository();
      await repository.addItem(_textItem('txt', 'Text to correct'));
      // Added last, so it is the newest entry and the pane opens on it.
      await repository.addItem(_imageItem('img', '/tmp/does-not-exist.png'));
      final ClipboardWatcherService service =
          await pumpSheet(tester, repository);

      // An image has no body to rewrite, and a control that does nothing is
      // worse than none.
      expect(find.text('EDIT'), findsNothing);

      await tester.tap(
        find.descendant(
          of: find.byKey(ClipboardHistorySheet.listKey),
          matching: find.text('Text to correct'),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('EDIT'), findsOneWidget);

      service.dispose();
    });

    testWidgets('an edit is saved when the field loses focus', (
      WidgetTester tester,
    ) async {
      final _MemoryClipboardRepository repository = _MemoryClipboardRepository();
      await repository.addItem(_textItem('1', 'Before the fix'));
      final ClipboardWatcherService service =
          await pumpOneEntry(tester, repository);

      await tester.tap(find.text('EDIT'));
      await tester.pump(const Duration(milliseconds: 100));

      final Finder field = find.descendant(
        of: find.byKey(ClipboardHistorySheet.previewKey),
        matching: find.byType(TextField),
      );
      expect(field, findsOneWidget);

      await tester.enterText(field, 'After the fix');
      await tester.pump(const Duration(milliseconds: 100));

      // Leaving the mode flushes what is pending.
      await tester.tap(find.text('DONE'));
      await tester.pump(const Duration(milliseconds: 100));

      expect(repository.items.single.text, 'After the fix');

      service.dispose();
    });

    testWidgets('selecting another entry mid-edit saves rather than discards', (
      WidgetTester tester,
    ) async {
      // This is the whole point of committing on focus loss instead of on a
      // SAVE button: the row tap must not have to be refused or to lose text.
      final _MemoryClipboardRepository repository = _MemoryClipboardRepository();
      await repository.addItem(_textItem('1', 'Older entry'));
      await repository.addItem(_textItem('2', 'Newer entry'));
      final ClipboardWatcherService service =
          await pumpOneEntry(tester, repository);

      await tester.tap(find.text('EDIT'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(
        find.descendant(
          of: find.byKey(ClipboardHistorySheet.previewKey),
          matching: find.byType(TextField),
        ),
        'Newer entry, corrected',
      );
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(
        find.descendant(
          of: find.byKey(ClipboardHistorySheet.listKey),
          matching: find.text('Older entry'),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      expect(
        repository.items.firstWhere((ClipboardItem e) => e.id == '2').text,
        'Newer entry, corrected',
      );

      service.dispose();
    });

    testWidgets('a dirty field says UNSAVED and reverts on demand', (
      WidgetTester tester,
    ) async {
      final _MemoryClipboardRepository repository = _MemoryClipboardRepository();
      await repository.addItem(_textItem('1', 'Original'));
      final ClipboardWatcherService service =
          await pumpOneEntry(tester, repository);

      await tester.tap(find.text('EDIT'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('UNSAVED'), findsNothing);

      await tester.enterText(
        find.descendant(
          of: find.byKey(ClipboardHistorySheet.previewKey),
          matching: find.byType(TextField),
        ),
        'Typed but not committed',
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('UNSAVED'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Revert the edit'));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('UNSAVED'), findsNothing);
      expect(repository.items.single.text, 'Original');

      service.dispose();
    });

    testWidgets('an emptied field never overwrites the entry', (
      WidgetTester tester,
    ) async {
      final _MemoryClipboardRepository repository = _MemoryClipboardRepository();
      await repository.addItem(_textItem('1', 'Keep me'));
      final ClipboardWatcherService service =
          await pumpOneEntry(tester, repository);

      await tester.tap(find.text('EDIT'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(
        find.descendant(
          of: find.byKey(ClipboardHistorySheet.previewKey),
          matching: find.byType(TextField),
        ),
        '   ',
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('DONE'));
      await tester.pump(const Duration(milliseconds: 100));

      expect(repository.items.single.text, 'Keep me');

      service.dispose();
    });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/clipboard_history_test.dart --plain-name "EDIT is offered for text"`
Expected: FAIL — `find.text('EDIT')` nie znajduje nic.

- [ ] **Step 3: Add the edit state to the sheet**

W `_ClipboardHistorySheetState`, po `String? _handoffNotice;` (linia 100):

```dart
  /// The entry being edited, or null. An **id, not the item**, for the same
  /// reason `_selectedId` is one — and it lives here rather than in
  /// [_ClipboardPreview] because changing the selection has to be able to flush
  /// a pending edit, which a parent cannot do by reaching into a child's state.
  String? _editingId;

  final TextEditingController _editController = TextEditingController();

  /// The last value taken **from the entry**. `dirty` is a difference from
  /// this, exactly as `_syncedText` works in `RecordingEditor`.
  String _syncedText = '';

  bool get _isEditDirty => _editController.text != _syncedText;
```

W `dispose()` (linia 113) dopisz przed `super.dispose()`:

```dart
    _editController.dispose();
```

- [ ] **Step 4: Add the edit lifecycle methods**

W `_ClipboardHistorySheetState`, po `_manageCollections`:

```dart
  void _startEdit(ClipboardItem item) {
    setState(() {
      _editingId = item.id;
      _syncedText = item.text ?? '';
      _editController.text = _syncedText;
      _handoffNotice = null;
    });
  }

  /// Writes the pending text if there is any worth writing.
  ///
  /// Blank is not an edit: an entry with no body cannot be pasted or searched,
  /// and deletion has its own action.
  Future<void> _commitEdit() async {
    final String? id = _editingId;
    if (id == null || !_isEditDirty) return;
    final String text = _editController.text;
    if (text.trim().isEmpty) return;
    _syncedText = text;
    await widget.watcherService.updateItemText(id, text);
  }

  Future<void> _endEdit() async {
    await _commitEdit();
    if (!mounted) return;
    setState(() => _editingId = null);
  }

  void _revertEdit() {
    setState(() => _editController.text = _syncedText);
  }

  /// Selection changes go through here so a pending edit is never lost.
  Future<void> _select(String id) async {
    await _endEdit();
    if (!mounted) return;
    setState(() {
      _selectedId = id;
      _handoffNotice = null;
    });
  }
```

- [ ] **Step 5: Route every selection change through `_select`**

W `itemBuilder` (linia 526) zamień:

```dart
          onTap: () => setState(() {
            _selectedId = item.id;
            _handoffNotice = null;
          }),
```

na:

```dart
          onTap: () => _select(item.id),
```

W `_move` (linia 145) zamień `setState(() => _selectedId = visible[next].id);` na:

```dart
    unawaited(_select(visible[next].id));
```

i dopisz `import 'dart:async';` na górze pliku, jeśli go nie ma. Strzałki
przesuwają zaznaczenie, więc muszą zapisywać dokładnie tak samo jak klik.

W `_handleKey` (linia 177) dopisz gałąź dla `Escape`, przed zamknięciem metody:

```dart
    } else if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (_editingId != null) unawaited(_endEdit());
    }
```

- [ ] **Step 6: Pass the edit state into the preview**

W `_buildPreview` (linia 558) rozszerz konstrukcję `_ClipboardPreview`:

```dart
    return _ClipboardPreview(
      key: ClipboardHistorySheet.previewKey,
      item: selected,
      notice: _handoffNotice,
      onPaste: () => _paste(context, selected),
      onConvert: _canConvert(selected)
          ? () => _convertToCapture(context, selected)
          : null,
      onCollections: () => _manageCollections(context, selected),
      onDelete: () => _delete(selected, visible),
      editing: _editingId == selected.id,
      editController: _editController,
      dirty: _isEditDirty,
      onEdit: () => _startEdit(selected),
      onEndEdit: () => unawaited(_endEdit()),
      onRevert: _revertEdit,
      onEditFocusLost: () => unawaited(_commitEdit()),
    );
```

- [ ] **Step 7: Render the field, the marker and the actions**

W `_ClipboardPreview` dopisz pola do konstruktora i klasy:

```dart
    required this.editing,
    required this.editController,
    required this.dirty,
    required this.onEdit,
    required this.onEndEdit,
    required this.onRevert,
    required this.onEditFocusLost,
```

```dart
  final bool editing;
  final TextEditingController editController;
  final bool dirty;
  final VoidCallback onEdit;
  final VoidCallback onEndEdit;
  final VoidCallback onRevert;
  final VoidCallback onEditFocusLost;
```

W `build`, w nagłówku, po `CopyButton` (linia 893), dopisz do tego samego `Row`:

```dart
              if (editing && dirty) ...<Widget>[
                const SizedBox(width: 10),
                // Same marker as `RecordingEditor` in the Queue, down to the
                // token: a plain amber micro label, not a StatusPill, because a
                // pill would read as a state of the entry rather than a warning
                // about the field.
                Text(
                  'UNSAVED',
                  style: ConsoleText.micro.copyWith(color: Console.amber),
                ),
                const SizedBox(width: 4),
                ConsoleIconButton(
                  icon: Icons.undo_rounded,
                  semanticLabel: 'Revert the edit',
                  onTap: onRevert,
                  size: 30,
                  iconSize: 15,
                ),
              ],
```

W ramce treści (linie 923–951) zamień gałąź tekstową tak, żeby w trybie edycji
renderowała pole. Warunek `isImage` zostaje nadrzędny — obraz nigdy nie wchodzi
w edycję:

```dart
              child: isImage && item.imagePath != null
                  ? Center(/* ...bez zmian... */)
                  : editing
                  ? Focus(
                      onFocusChange: (bool hasFocus) {
                        if (!hasFocus) onEditFocusLost();
                      },
                      child: TextField(
                        controller: editController,
                        autofocus: true,
                        maxLines: null,
                        expands: false,
                        style: TextStyle(
                          fontFamily: ConsoleFont.mono,
                          fontSize: 12.5,
                          height: 1.6,
                          color: Console.text,
                        ),
                        decoration: const InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    )
                  : SingleChildScrollView(/* ...bez zmian... */),
```

W stopce (linia 968) wstaw akcję między `TO CAPTURE` a `COLLECTIONS`:

```dart
              if (!isImage)
                _PreviewAction(
                  label: editing ? 'DONE' : 'EDIT',
                  icon: editing ? Icons.check_rounded : Icons.edit_outlined,
                  onPressed: editing ? onEndEdit : onEdit,
                  color: editing ? Console.accent : null,
                ),
```

Pozostałe akcje zostają aktywne w trybie edycji: zapis przy utracie fokusu
oznacza, że nie istnieje stan „niezapisane, więc nie wolno".

- [ ] **Step 8: Run tests to verify they pass**

Run: `flutter test test/clipboard_history_test.dart`
Expected: PASS — pięć nowych testów plus wszystkie wcześniejsze.

- [ ] **Step 9: Prove the tests are not vacuous**

Skopiuj plik poza repozytorium, zepsuj implementację, sprawdź czerwień, przywróć.
**Nie używaj `git checkout -- <plik>`** — w brudnym drzewie cofa do `HEAD` i
zabiera ze sobą wszystkie inne niezacommitowane zmiany w tym pliku.

```bash
cp lib/features/clipboard/presentation/clipboard_history_sheet.dart /tmp/sheet.bak
```

W `_select` usuń `await _endEdit();`, czyli zmiana zaznaczenia przestaje
zapisywać:

```bash
flutter test test/clipboard_history_test.dart \
  --plain-name "selecting another entry mid-edit saves rather than discards"
```

Expected: FAIL — `Expected: 'Newer entry, corrected' / Actual: 'Newer entry'`.
Test, który nigdy nie był czerwony, jest założeniem, a nie sprawdzeniem.

```bash
cp /tmp/sheet.bak lib/features/clipboard/presentation/clipboard_history_sheet.dart
flutter test test/clipboard_history_test.dart \
  --plain-name "selecting another entry mid-edit saves rather than discards"
```

Expected: PASS

- [ ] **Step 10: Run the whole gate**

Run: `flutter analyze && flutter test`
Expected: brak błędów; cały zestaw zielony. `test/theme_test.dart` pilnuje, że
nic nowego nie jest konstruowane z `const`.

- [ ] **Step 11: Run the app and look at it**

```bash
flutter run -d macos
```

Sprawdź na oko:
1. `Ctrl+Alt+V` — `EDIT` jest w podglądzie wpisu tekstowego, nie ma go przy obrazku
2. `EDIT` zamienia treść na pole, kursor jest w polu, czcionka **nie skacze**
3. popraw treść, kliknij inny wiersz — poprzedni wpis ma nową treść i **zostaje na swojej pozycji**, nie skacze na górę listy
4. w trakcie pisania pojawia się `UNSAVED`; cofnięcie przywraca tekst i znacznik znika
5. wyczyść pole do zera i kliknij `DONE` — wpis zostaje nietknięty
6. `Escape` w trybie edycji wychodzi z niego, zapisując
7. przełącz motyw w Config na jasny i wróć — pole i znacznik są jasne

- [ ] **Step 12: Commit**

```bash
git add lib/features/clipboard/presentation/clipboard_history_sheet.dart \
        test/clipboard_history_test.dart
git commit -m "Edit a clipboard entry in place in the preview pane"
```

---

## Self-review planu

**Pokrycie specu.** `previewFor` → Task 1; `updateItemText` z regułami
(`copiedAt`, pusty tekst, obraz, nieznane `id`) → Task 2 i 3; serwis → Task 4;
tryb edycji, zapis na utratę fokusu, `UNSAVED` z cofnięciem, `EDIT` ukryte na
obrazach, `Escape` → Task 5. Sekcja „Czego ta zmiana nie dotyka" nie generuje
zadań.

**Jedna luka świadomie zostawiona.**
`SqliteClipboardRepository.updateItemText` nie ma testu automatycznego — żaden
test nie konstruuje `AppDatabase`, a dorabianie do tego infrastruktury byłoby
większą zmianą niż sama funkcja; pokrywa ją analyze, symetria z wersją plikową i
ręczny przebieg z Task 5 Step 11, który idzie właśnie przez SQLite.

**API sprawdzone w kodzie, nie z pamięci.** `Console.amber` istnieje
(`ui_kit.dart:267`, `0xFFF6AE31` / `0xFF9F6604`); `ConsoleIconButton` przyjmuje
`icon` / `onTap` / `semanticLabel` / `size` / `iconSize` (1094); wzorzec
znacznika pochodzi z `recording_editor.dart:411-418`. Żaden nowy surowy hex nie
jest wprowadzany — wszystkie należą do `ConsolePalette`.

**Spójność nazw.** `updateItemText(String id, String text)` — identycznie w
interfejsie, obu implementacjach, fake'u i serwisie. `previewFor`/`previewLength`
w Task 1–3. `_editingId`, `_editController`, `_syncedText`, `_startEdit`,
`_commitEdit`, `_endEdit`, `_revertEdit`, `_select`, `_isEditDirty` — wyłącznie
Task 5. Etykiety `EDIT` / `DONE` / `UNSAVED` i semantyka `Revert the edit` to te
same łańcuchy w implementacji i w pięciu testach.
