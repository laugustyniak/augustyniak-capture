# Edycja wpisów w historii schowka — plan wdrożenia

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ołówek na tekstowym wpisie historii schowka otwiera okno, w którym można poprawić treść i przypisać kolekcje; zapis nadpisuje wpis w miejscu.

**Architecture:** Nowa metoda `updateItem` w interfejsie `ClipboardRepository` (dwie implementacje: plikowa i SQLite) przechodzi przez cienkie `ClipboardWatcherService.updateItem` do nowego dialogu `_ClipboardEditDialog`. Dialog trzyma odłożoną kopię tekstu i kolekcji i zapisuje wszystko jednym wywołaniem dopiero na `SAVE`; znacznik `copiedAt` nigdy się nie zmienia, dzięki czemu wpis zostaje na swojej pozycji na liście.

**Tech Stack:** Flutter / Dart 3.10, `sqlite3`, `flutter_test`. Bez nowych zależności.

**Spec:** `docs/superpowers/specs/2026-08-09-clipboard-item-editing-design.md`

## ⚠ Zależność — wykonać najpierw

**Task 2 z planu `docs/superpowers/plans/2026-08-09-english-only-strings.md` musi wylądować przed Taskiem 5 tego planu.** Tamten task tłumaczy arkusz schowka na angielski i zwija zduplikowaną listę domyślnych kolekcji w stałą `kDefaultClipboardCollections`. Bez niego Task 5 albo dopisze trzecią kopię tej listy, albo wprowadzi angielskie napisy do arkusza, który jest jeszcze polski.

Taski 1–4 tego planu są językowo neutralne (repozytoria, serwis, `previewFor`) i mogą wejść w dowolnej kolejności względem tamtego planu.

Sprawdzenie, czy zależność jest spełniona:

```bash
grep -n "kDefaultClipboardCollections" lib/features/clipboard/presentation/clipboard_history_sheet.dart
```

Brak wyniku znaczy, że Task 2 tamtego planu jeszcze nie wszedł — **zatrzymaj się i wykonaj go najpierw.**

## Global Constraints

- **Wszystkie napisy i komentarze w kodzie po angielsku.** CLAUDE.md: *„user-facing strings in code are English — do not reintroduce Polish"*, i to samo dotyczy identyfikatorów oraz komentarzy. Feature `clipboard` był wyjątkiem; plan English-only ten wyjątek likwiduje, a `test/language_test.dart` (jego Task 3) zacznie tego pilnować automatycznie.
- **Żaden widget malujący paletę `Console` nie może być konstruowany z `const`.** `test/theme_test.dart:302` skanuje `lib/` regexem `const _Widget(` i zgłosi takie miejsce jako błąd. Powód: Flutter pomija przebudowę widgetu identycznego z poprzednim, więc `const` przypina stary motyw po przełączeniu. Sama deklaracja konstruktora jako `const` jest dozwolona — zakazane jest `const` w miejscu wywołania.
- **Nigdy `tester.pumpAndSettle()` na ekranie z autofocusowanym `TextField`** — migający kursor to animacja bez końca, więc „brak zaplanowanych klatek" nigdy nie nastąpi i test wisi do timeoutu. Używamy `tester.pump(const Duration(milliseconds: N))`.
- **Nie ma CI.** `flutter analyze && flutter test` lokalnie jest twardą bramką. Hook `pre-push` uruchamia oba, jeśli włączono `git config core.hooksPath .githooks`.
- **`copiedAt` nie zmienia się nigdy** przy edycji — to mechanizm realizujący „nadpisz w miejscu".
- Wszystkie testy tej zmiany trafiają do `test/clipboard_history_test.dart`. Plik `test/clipboard_test.dart` mimo nazwy dotyczy `ClipboardSink` w potoku nagrań i nie jest tu ruszany.

## Struktura plików

| Plik | Rola po zmianie |
| --- | --- |
| `lib/features/clipboard/domain/clipboard_item.dart` | + `static String previewFor(String)` — jedyna definicja skrótu podglądu |
| `lib/features/clipboard/domain/clipboard_watcher_service.dart` | korzysta z `previewFor`; + `updateItem` delegujące do repozytorium |
| `lib/features/clipboard/data/clipboard_repository.dart` | + `updateItem` w interfejsie i w implementacji plikowej |
| `lib/features/clipboard/data/sqlite_clipboard_repository.dart` | + `updateItem` na `UPDATE ... WHERE id = ?` |
| `lib/features/clipboard/presentation/clipboard_history_sheet.dart` | + ołówek na wierszu tekstowym, + `_ClipboardEditDialog`, + wspólny `_askCollectionName` |
| `test/clipboard_history_test.dart` | + testy repozytorium, serwisu i dialogu; `_MemoryClipboardRepository` dostaje `updateItem` |

---

### Task 1: `ClipboardItem.previewFor` — jedna definicja podglądu

Reguła skrótu podglądu żyje dziś inline w watcherze. Edycja będzie drugim miejscem, które musi ją policzyć, więc najpierw wyciągamy ją do domeny.

**Files:**
- Modify: `lib/features/clipboard/domain/clipboard_item.dart`
- Modify: `lib/features/clipboard/domain/clipboard_watcher_service.dart:124`
- Test: `test/clipboard_history_test.dart` (grupa `ClipboardItem`)

**Interfaces:**
- Consumes: nic
- Produces: `static String ClipboardItem.previewFor(String text)` — zwraca `text`, gdy `text.length <= 120`, w przeciwnym razie pierwsze 120 znaków sklejone z `'...'`; oraz `static const int ClipboardItem.previewLength = 120`

- [ ] **Step 1: Write the failing test**

W `test/clipboard_history_test.dart`, wewnątrz istniejącej grupy `group('ClipboardItem', ...)`, dopisz po teście `serialization roundtrip with collections`:

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
Expected: FAIL — błąd kompilacji `The method 'previewFor' isn't defined for the type 'ClipboardItem'`.

- [ ] **Step 3: Write minimal implementation**

W `lib/features/clipboard/domain/clipboard_item.dart`, wewnątrz klasy `ClipboardItem`, tuż nad `Map<String, dynamic> toJson()`:

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

- [ ] **Step 5: Przełącz watcher na wspólną funkcję**

W `lib/features/clipboard/domain/clipboard_watcher_service.dart` zamień w `checkNow()` (obecnie linia 124):

```dart
          preview: text.length > 120 ? '${text.substring(0, 120)}...' : text,
```

na:

```dart
          preview: ClipboardItem.previewFor(text),
```

- [ ] **Step 6: Run the full clipboard suite**

Run: `flutter test test/clipboard_history_test.dart`
Expected: PASS — wszystkie testy, łącznie z `captures new text and image once and copies through the gateway`, który przechodzi przez zmienioną linię.

- [ ] **Step 7: Commit**

```bash
git add lib/features/clipboard/domain/clipboard_item.dart \
        lib/features/clipboard/domain/clipboard_watcher_service.dart \
        test/clipboard_history_test.dart
git commit -m "Extract the clipboard preview rule into ClipboardItem.previewFor"
```

---

### Task 2: `updateItem` w interfejsie i w repozytorium plikowym

**Files:**
- Modify: `lib/features/clipboard/data/clipboard_repository.dart` (interfejs `ClipboardRepository` + `LocalJsonClipboardRepository`)
- Modify: `lib/features/clipboard/data/sqlite_clipboard_repository.dart` (tymczasowe rusztowanie, patrz Step 5)
- Modify: `test/clipboard_history_test.dart` (fake `_MemoryClipboardRepository`, linia ~337)
- Test: `test/clipboard_history_test.dart` (grupa `ClipboardRepository`)

**Interfaces:**
- Consumes: `ClipboardItem.previewFor(String)` z Task 1
- Produces: `Future<void> ClipboardRepository.updateItem(String id, {String? text, Set<String>? collections})` — `null` znaczy „nie ruszaj tego pola"; `copiedAt` nietknięte; puste/białe `text` ignorowane; `text` na wpisie `image` ignorowane; nieznane `id` to no-op

**Uwaga o kolejności:** dodanie metody do interfejsu psuje kompilację `SqliteClipboardRepository` (Task 3) i fake'a `_MemoryClipboardRepository`. Fake naprawiamy w tym zadaniu (Step 4), bo bez niego plik testowy się nie skompiluje. Implementacja SQLite dostaje w tym zadaniu wersję tymczasową rzucającą `UnimplementedError`, żeby drzewo się budowało; Task 3 zastępuje ją prawdziwą. To jedyne miejsce w planie, gdzie takie rusztowanie jest potrzebne — Dart nie pozwala zostawić klasy bez implementacji metody interfejsu.

- [ ] **Step 1: Write the failing tests**

W `test/clipboard_history_test.dart`, wewnątrz `group('ClipboardRepository', ...)`, dopisz po teście `preserves an unreadable history before starting empty`:

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

      await repository.updateItem('2', text: 'Second, corrected');

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
      await repository.updateItem('1', text: long);

      expect(repository.items.single.text, long);
      expect(repository.items.single.preview, '${'z' * 120}...');
    });

    test('blank text leaves the item untouched', () async {
      await repository.initialize();
      await repository.addItem(_textItem('1', 'Original'));

      await repository.updateItem('1', text: '');
      expect(repository.items.single.text, 'Original');

      await repository.updateItem('1', text: '   \n  ');
      expect(repository.items.single.text, 'Original');
    });

    test('an image ignores text but accepts collections', () async {
      await repository.initialize();
      await repository.addItem(_imageItem('img', '${tempDir.path}/a.png'));

      await repository.updateItem(
        'img',
        text: 'this must not get in',
        collections: <String>{'Favorites'},
      );

      final ClipboardItem item = repository.items.single;
      expect(item.text, isNull);
      expect(item.collections, <String>{'Favorites'});
    });

    test('collections are replaced wholesale, not merged', () async {
      await repository.initialize();
      await repository.addItem(_textItem('1', 'Text'));
      await repository.toggleItemCollection('1', 'Code');

      await repository.updateItem('1', collections: <String>{'Prompts'});

      expect(repository.items.single.collections, <String>{'Prompts'});
    });

    test('an unknown id is a silent no-op', () async {
      await repository.initialize();
      await repository.addItem(_textItem('1', 'Text'));

      await repository.updateItem('no-such-id', text: 'anything');

      expect(repository.items, hasLength(1));
      expect(repository.items.single.text, 'Text');
    });

    test('an edit survives reloading the repository from disk', () async {
      await repository.initialize();
      await repository.addItem(_textItem('1', 'Before'));
      await repository.updateItem(
        '1',
        text: 'After',
        collections: <String>{'Important'},
      );

      final LocalJsonClipboardRepository restored = LocalJsonClipboardRepository(
        maxItems: 3,
        storageDirectoryProvider: () async => tempDir,
      );
      await restored.initialize();

      expect(restored.items.single.text, 'After');
      expect(restored.items.single.collections, <String>{'Important'});
    });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/clipboard_history_test.dart`
Expected: FAIL — błąd kompilacji `The method 'updateItem' isn't defined for the type 'ClipboardRepository'`.

- [ ] **Step 3: Add the method to the interface and the file-backed implementation**

W `lib/features/clipboard/data/clipboard_repository.dart` dopisz do `abstract class ClipboardRepository`, między `addItem` a `toggleItemCollection`:

```dart
  /// Overwrites an entry in place. `null` means "leave this field alone".
  ///
  /// `copiedAt` never changes, so a correction does not push the entry back to
  /// the top of the list. Blank text, and text for an image entry, are ignored.
  Future<void> updateItem(String id, {String? text, Set<String>? collections});
```

Do `LocalJsonClipboardRepository`, po `addItem`:

```dart
  @override
  Future<void> updateItem(
    String id, {
    String? text,
    Set<String>? collections,
  }) async {
    if (!_initialized) await initialize();
    final int index = _items.indexWhere((ClipboardItem item) => item.id == id);
    if (index == -1) return;

    final ClipboardItem current = _items[index];
    final bool rewritesText =
        text != null &&
        text.trim().isNotEmpty &&
        current.type == ClipboardItemType.text;

    if (!rewritesText && collections == null) return;

    _items[index] = current.copyWith(
      text: rewritesText ? text : null,
      preview: rewritesText ? ClipboardItem.previewFor(text) : null,
      collections: collections,
    );
    await _save();
  }
```

`copyWith` traktuje `null` jako „zachowaj obecną wartość", więc przekazanie `null` w gałęzi „nie przepisujemy tekstu" jest dokładnie tym, o co chodzi.

- [ ] **Step 4: Teach the test fake the new method**

W `test/clipboard_history_test.dart`, w klasie `_MemoryClipboardRepository`, dopisz po `toggleItemCollection`:

```dart
  @override
  Future<void> updateItem(
    String id, {
    String? text,
    Set<String>? collections,
  }) async {
    final int index = _items.indexWhere((ClipboardItem item) => item.id == id);
    if (index < 0) return;
    final ClipboardItem current = _items[index];
    final bool rewritesText =
        text != null &&
        text.trim().isNotEmpty &&
        current.type == ClipboardItemType.text;
    if (!rewritesText && collections == null) return;
    _items[index] = current.copyWith(
      text: rewritesText ? text : null,
      preview: rewritesText ? ClipboardItem.previewFor(text) : null,
      collections: collections,
    );
  }
```

- [ ] **Step 5: Add a temporary SQLite implementation so the tree compiles**

W `lib/features/clipboard/data/sqlite_clipboard_repository.dart`, po `addItem`:

```dart
  @override
  Future<void> updateItem(
    String id, {
    String? text,
    Set<String>? collections,
  }) async {
    throw UnimplementedError('Task 3 of this plan supplies the real body.');
  }
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `flutter test test/clipboard_history_test.dart`
Expected: PASS — wszystkie, łącznie z siedmioma nowymi.

- [ ] **Step 7: Commit**

```bash
git add lib/features/clipboard/data/clipboard_repository.dart \
        lib/features/clipboard/data/sqlite_clipboard_repository.dart \
        test/clipboard_history_test.dart
git commit -m "Add ClipboardRepository.updateItem and its file-backed implementation"
```

---

### Task 3: `updateItem` w repozytorium SQLite

To jest implementacja używana w produkcji (`recordings_page.dart:269`). Nie da się jej pokryć testem w tym repozytorium — wymaga `AppDatabase.getInstance()`, które idzie po `path_provider` i realny plik bazy, a żaden istniejący test tego nie robi. Dlatego trzyma się mechanicznie blisko wersji plikowej z Task 2, a weryfikacją jest `flutter analyze` plus ręczne uruchomienie z Task 5.

**Files:**
- Modify: `lib/features/clipboard/data/sqlite_clipboard_repository.dart`

**Interfaces:**
- Consumes: `ClipboardItem.previewFor(String)` z Task 1; sygnatura `updateItem` z Task 2
- Produces: nic nowego

- [ ] **Step 1: Replace the temporary implementation**

W `lib/features/clipboard/data/sqlite_clipboard_repository.dart` zastąp ciało `updateItem` z Task 2 Step 5 przez:

```dart
  @override
  Future<void> updateItem(
    String id, {
    String? text,
    Set<String>? collections,
  }) async {
    final AppDatabase db = _appDatabase ?? await AppDatabase.getInstance();
    final int index = _items.indexWhere((ClipboardItem item) => item.id == id);
    if (index == -1) return;

    final ClipboardItem current = _items[index];
    final bool rewritesText =
        text != null &&
        text.trim().isNotEmpty &&
        current.type == ClipboardItemType.text;

    if (!rewritesText && collections == null) return;

    // copied_at is deliberately untouched: getItems() reads
    // ORDER BY copied_at DESC, so the entry keeps its place in the list.
    if (rewritesText) {
      db.rawDb.execute(
        'UPDATE clipboard_items SET text = ?, preview = ? WHERE id = ?;',
        <Object?>[text, ClipboardItem.previewFor(text), id],
      );
    }
    if (collections != null) {
      db.rawDb.execute(
        'UPDATE clipboard_items SET collections_json = ? WHERE id = ?;',
        <Object?>[jsonEncode(collections.toList()), id],
      );
    }

    await getItems();
  }
```

`jsonEncode` jest już zaimportowane w tym pliku (`dart:convert`, linia 1).

- [ ] **Step 2: Verify the tree analyzes clean**

Run: `flutter analyze`
Expected: `No issues found!`

- [ ] **Step 3: Run the whole suite**

Run: `flutter test`
Expected: PASS — żaden test nie dotyka tej klasy, więc chodzi wyłącznie o to, że nic się nie zepsuło.

- [ ] **Step 4: Commit**

```bash
git add lib/features/clipboard/data/sqlite_clipboard_repository.dart
git commit -m "Implement updateItem in the SQLite clipboard repository"
```

---

### Task 4: `ClipboardWatcherService.updateItem`

**Files:**
- Modify: `lib/features/clipboard/domain/clipboard_watcher_service.dart`
- Test: `test/clipboard_history_test.dart` (grupa `ClipboardWatcherService & Sheet Widget`)

**Interfaces:**
- Consumes: `ClipboardRepository.updateItem` z Task 2
- Produces: `Future<void> ClipboardWatcherService.updateItem(String id, {String? text, Set<String>? collections})` — deleguje i woła `notifyListeners()`

- [ ] **Step 1: Write the failing test**

W `test/clipboard_history_test.dart`, wewnątrz `group('ClipboardWatcherService & Sheet Widget', ...)`, dopisz po teście `still captures text when native image support is unavailable`:

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

      await service.updateItem(
        '1',
        text: 'After',
        collections: <String>{'Code'},
      );

      expect(repository.items.single.text, 'After');
      expect(repository.items.single.collections, <String>{'Code'});
      expect(notifications, 1);
      // Saving an edit must not replace what the user currently has copied.
      expect(gateway.copiedText, isNull);
      expect(gateway.copiedImagePath, isNull);

      service.dispose();
    });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/clipboard_history_test.dart --plain-name "editing an item notifies listeners"`
Expected: FAIL — `The method 'updateItem' isn't defined for the type 'ClipboardWatcherService'`.

- [ ] **Step 3: Write minimal implementation**

W `lib/features/clipboard/domain/clipboard_watcher_service.dart`, po `toggleItemCollection`:

```dart
  /// Overwrites an entry in place.
  ///
  /// Deliberately leaves `_lastText` and `_lastImagePath` alone: an edit never
  /// writes to the system clipboard, so the next poll sees nothing new and no
  /// duplicate of our own edit is captured.
  Future<void> updateItem(
    String id, {
    String? text,
    Set<String>? collections,
  }) async {
    await _repository.updateItem(id, text: text, collections: collections);
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
git commit -m "Add ClipboardWatcherService.updateItem"
```

---

### Task 5: Ołówek na wierszu i okno edycji

Największe zadanie i jedyne z widoczną zmianą. Kończy się ręcznym uruchomieniem aplikacji — dla zmiany wizualnej zielony test opisuje tylko to, o co go zapytano, a CLAUDE.md zapisuje przypadek, w którym pełny zestaw testów przeszedł nad zepsutym wyglądem.

**⚠ Wymaga Taska 2 z planu `2026-08-09-english-only-strings.md`.** Sprawdź `grep -n "kDefaultClipboardCollections" lib/features/clipboard/presentation/clipboard_history_sheet.dart` — brak wyniku znaczy „zatrzymaj się".

**Files:**
- Modify: `lib/features/clipboard/presentation/clipboard_history_sheet.dart`
- Test: `test/clipboard_history_test.dart` (grupa `ClipboardWatcherService & Sheet Widget`)

**Interfaces:**
- Consumes: `ClipboardWatcherService.updateItem` z Task 4; `ClipboardWatcherService.allCollections` (istnieje); `kDefaultClipboardCollections` z planu English-only
- Produces: prywatne dla pliku — `_ClipboardEdit`, `_ClipboardEditDialog`, `_askCollectionName`; `_ClipboardItemTile` dostaje pole `final VoidCallback? onEdit`

- [ ] **Step 1: Write the failing tests**

W `test/clipboard_history_test.dart`, wewnątrz `group('ClipboardWatcherService & Sheet Widget', ...)`, dopisz:

```dart
    testWidgets('the pencil is on text rows and absent on image rows', (
      WidgetTester tester,
    ) async {
      final _MemoryClipboardRepository repository = _MemoryClipboardRepository();
      await repository.addItem(_imageItem('img', '/tmp/does-not-exist.png'));
      await repository.addItem(_textItem('txt', 'Text to correct'));
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

      // Two rows on the list, but only the text one carries a pencil.
      expect(find.byTooltip('Edit entry text'), findsOneWidget);

      service.dispose();
    });

    testWidgets('saving an edit rewrites the item', (
      WidgetTester tester,
    ) async {
      final _MemoryClipboardRepository repository = _MemoryClipboardRepository();
      await repository.addItem(_textItem('1', 'Before the fix'));
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

      await tester.tap(find.byTooltip('Edit entry text'));
      await tester.pump(const Duration(milliseconds: 300));

      final Finder dialogField = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      expect(dialogField, findsOneWidget);

      await tester.enterText(dialogField, 'After the fix');
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(FilterChip, 'Code'),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('SAVE'));
      await tester.pump(const Duration(milliseconds: 300));

      expect(repository.items.single.text, 'After the fix');
      expect(repository.items.single.collections, <String>{'Code'});
      expect(find.byType(AlertDialog), findsNothing);

      service.dispose();
    });

    testWidgets('cancelling discards both the text and the collections', (
      WidgetTester tester,
    ) async {
      final _MemoryClipboardRepository repository = _MemoryClipboardRepository();
      await repository.addItem(_textItem('1', 'Untouched'));
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

      await tester.tap(find.byTooltip('Edit entry text'));
      await tester.pump(const Duration(milliseconds: 300));

      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        'This must disappear',
      );
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(FilterChip, 'Code'),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('CANCEL'));
      await tester.pump(const Duration(milliseconds: 300));

      expect(repository.items.single.text, 'Untouched');
      expect(repository.items.single.collections, isEmpty);

      service.dispose();
    });

    testWidgets('an empty edit cannot be saved', (WidgetTester tester) async {
      final _MemoryClipboardRepository repository = _MemoryClipboardRepository();
      await repository.addItem(_textItem('1', 'Something'));
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

      await tester.tap(find.byTooltip('Edit entry text'));
      await tester.pump(const Duration(milliseconds: 300));

      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        '   ',
      );
      await tester.pump(const Duration(milliseconds: 100));

      final ElevatedButton save = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'SAVE'),
      );
      expect(save.onPressed, isNull);

      service.dispose();
    });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/clipboard_history_test.dart --plain-name "the pencil is on text rows"`
Expected: FAIL — `Expected: exactly one matching candidate / Actual: _TooltipMessageFinder:<zero widgets>`.

- [ ] **Step 3: Extract the shared collection-name prompt**

W `lib/features/clipboard/presentation/clipboard_history_sheet.dart` dodaj na końcu pliku, po klasie `_ClipboardItemTile`, wspólną funkcję — będzie używana przez istniejący `_promptNewCollection` (który ustawia filtr) i przez nowy dialog (który dopisuje do odłożonego zbioru):

```dart
/// Asks for a collection name and returns it, or `null` if the user backed out.
///
/// Shared by the sheet's collection strip and by the edit dialog: the two do
/// different things with the answer, but they ask exactly the same question.
Future<String?> _askCollectionName(BuildContext context) {
  final TextEditingController nameController = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (BuildContext context) => ConsolePaletteScope(
      builder: (BuildContext context) => AlertDialog(
        backgroundColor: Console.surface,
        title: Text(
          'NEW COLLECTION',
          style: TextStyle(
            fontFamily: ConsoleFont.display,
            fontSize: 16,
            color: Console.text,
          ),
        ),
        content: TextField(
          controller: nameController,
          autofocus: true,
          style: TextStyle(color: Console.text),
          decoration: InputDecoration(
            hintText: 'Collection name (e.g. Prompts, Code)...',
            hintStyle: TextStyle(color: Console.dimText),
            filled: true,
            fillColor: Console.surfaceRaised,
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('Cancel', style: TextStyle(color: Console.dimText)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Console.accent),
            onPressed: () {
              final String text = nameController.text.trim();
              if (text.isNotEmpty) {
                Navigator.of(context).pop(text);
              }
            },
            child: Text('Add', style: TextStyle(color: Console.ink)),
          ),
        ],
      ),
    ),
  );
}
```

Następnie zastąp całe ciało istniejącej metody `_promptNewCollection` przez:

```dart
  Future<void> _promptNewCollection(BuildContext context) async {
    final String? collectionName = await _askCollectionName(context);
    if (collectionName != null && collectionName.isNotEmpty) {
      setState(() {
        _selectedCollection = collectionName;
      });
    }
  }
```

- [ ] **Step 4: Add the staged-edit result holder and the dialog**

Nadal w `clipboard_history_sheet.dart`, po `_askCollectionName`:

```dart
/// The staged result of an edit — what the dialog returns on SAVE.
class _ClipboardEdit {
  _ClipboardEdit({required this.text, required this.collections});

  final String text;
  final Set<String> collections;
}

/// Editor for a single clipboard entry.
///
/// Every change, collection chips included, is staged and only written on SAVE.
/// This deliberately departs from `RecordingEditor`'s "a chip writes on the
/// tap" rule: that editor has no cancel button and this one does, so a dialog
/// that had already committed half of its changes would be a trap.
///
/// The constructor is not `const` and must not become one — the widget paints
/// the `Console` palette, and `const` would pin the old theme after a swap
/// (see `test/theme_test.dart`).
class _ClipboardEditDialog extends StatefulWidget {
  _ClipboardEditDialog({required this.item, required this.suggestions});

  final ClipboardItem item;
  final Set<String> suggestions;

  @override
  State<_ClipboardEditDialog> createState() => _ClipboardEditDialogState();
}

class _ClipboardEditDialogState extends State<_ClipboardEditDialog> {
  late final TextEditingController _textController;
  late Set<String> _collections;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: widget.item.text ?? '');
    _textController.addListener(_onTextChanged);
    _collections = Set<String>.from(widget.item.collections);
  }

  void _onTextChanged() => setState(() {});

  @override
  void dispose() {
    _textController.removeListener(_onTextChanged);
    _textController.dispose();
    super.dispose();
  }

  bool get _canSave => _textController.text.trim().isNotEmpty;

  Future<void> _addCollection() async {
    final String? name = await _askCollectionName(context);
    if (name == null || name.isEmpty) return;
    setState(() => _collections.add(name));
  }

  @override
  Widget build(BuildContext context) {
    final Set<String> chips = <String>{...widget.suggestions, ..._collections};

    return AlertDialog(
      backgroundColor: Console.surface,
      title: Text(
        'EDIT ENTRY',
        style: TextStyle(
          fontFamily: ConsoleFont.display,
          fontSize: 16,
          color: Console.text,
        ),
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              TextField(
                controller: _textController,
                autofocus: true,
                maxLines: 12,
                minLines: 4,
                style: TextStyle(
                  fontFamily: ConsoleFont.mono,
                  fontSize: 13,
                  color: Console.text,
                ),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: Console.surfaceRaised,
                  contentPadding: const EdgeInsets.all(12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: Console.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: Console.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: Console.accent),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                'COLLECTIONS',
                style: TextStyle(
                  fontFamily: ConsoleFont.display,
                  fontSize: 12,
                  letterSpacing: 1.1,
                  color: Console.dimText,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final String collection in chips)
                    FilterChip(
                      selected: _collections.contains(collection),
                      label: Text(collection),
                      labelStyle: TextStyle(
                        color: _collections.contains(collection)
                            ? Console.accent
                            : Console.text,
                        fontSize: 13,
                      ),
                      selectedColor: Console.accent.withValues(alpha: .2),
                      backgroundColor: Console.surfaceRaised,
                      onSelected: (bool selected) {
                        setState(() {
                          if (selected) {
                            _collections.add(collection);
                          } else {
                            _collections.remove(collection);
                          }
                        });
                      },
                    ),
                  ActionChip(
                    avatar: Icon(Icons.add, size: 16, color: Console.accent),
                    label: const Text('New'),
                    backgroundColor: Console.surfaceRaised,
                    labelStyle: TextStyle(color: Console.accent, fontSize: 12),
                    onPressed: _addCollection,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('CANCEL', style: TextStyle(color: Console.dimText)),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: Console.accent),
          onPressed: _canSave
              ? () => Navigator.of(context).pop(
                  _ClipboardEdit(
                    text: _textController.text,
                    collections: _collections,
                  ),
                )
              : null,
          child: Text('SAVE', style: TextStyle(color: Console.ink)),
        ),
      ],
    );
  }
}
```

- [ ] **Step 5: Open the dialog from the sheet**

W `_ClipboardHistorySheetState`, po metodzie `_manageItemCollections`:

```dart
  Future<void> _editItem(BuildContext context, ClipboardItem item) async {
    final _ClipboardEdit? edit = await showDialog<_ClipboardEdit>(
      context: context,
      builder: (BuildContext context) => ConsolePaletteScope(
        builder: (BuildContext context) => _ClipboardEditDialog(
          item: item,
          suggestions: <String>{
            ...kDefaultClipboardCollections,
            ...widget.watcherService.allCollections,
          },
        ),
      ),
    );
    if (edit == null) return;
    await widget.watcherService.updateItem(
      item.id,
      text: edit.text,
      collections: edit.collections,
    );
  }
```

Lista sugestii czytana jest ze stałej, a nie wpisana po raz trzeci — to ta sama zasada jednej definicji, dla której powstała `kDefaultClipboardCollections`.

- [ ] **Step 6: Give the tile a pencil**

W klasie `_ClipboardItemTile` dodaj parametr konstruktora po `onConvertToCapture`:

```dart
    this.onEdit,
```

oraz pole obok pozostałych:

```dart
  final VoidCallback? onEdit;
```

W metodzie `build`, w rzędzie akcji, **przed** blokiem `if (onConvertToCapture != null)`:

```dart
                          if (onEdit != null) ...<Widget>[
                            InkWell(
                              onTap: onEdit,
                              borderRadius: BorderRadius.circular(4),
                              child: Padding(
                                padding: const EdgeInsets.all(4.0),
                                child: Tooltip(
                                  message: 'Edit entry text',
                                  child: Icon(
                                    Icons.edit_outlined,
                                    size: 16,
                                    color: Console.muted,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                          ],
```

Na koniec, w `itemBuilder` arkusza, w wywołaniu `_ClipboardItemTile(...)`, dopisz po `onConvertToCapture:`:

```dart
                                onEdit: item.type == ClipboardItemType.text
                                    ? () => _editItem(context, item)
                                    : null,
```

Ołówka nie ma na wpisach obrazkowych, bo obraz nie ma treści do podmiany — kontrolka, która nic nie robi, jest gorsza niż jej brak.

- [ ] **Step 7: Run tests to verify they pass**

Run: `flutter test test/clipboard_history_test.dart`
Expected: PASS — cztery nowe testy widgetowe plus wszystkie wcześniejsze.

- [ ] **Step 8: Prove the tests are not vacuous**

Skopiuj plik poza repozytorium, zepsuj implementację, sprawdź czerwień, przywróć. **Nie używaj `git checkout -- <plik>`** — w brudnym drzewie cofa do `HEAD` i zabiera ze sobą wszystkie inne niezacommitowane zmiany w tym pliku.

```bash
cp lib/features/clipboard/presentation/clipboard_history_sheet.dart /tmp/sheet.bak
```

Zmień w `_editItem` linię `if (edit == null) return;` na `return;` (czyli zapis nigdy nie następuje) i uruchom:

```bash
flutter test test/clipboard_history_test.dart --plain-name "saving an edit rewrites the item"
```

Expected: FAIL — `Expected: 'After the fix' / Actual: 'Before the fix'`. Test, który nigdy nie był czerwony, jest założeniem, a nie sprawdzeniem.

```bash
cp /tmp/sheet.bak lib/features/clipboard/presentation/clipboard_history_sheet.dart
flutter test test/clipboard_history_test.dart --plain-name "saving an edit rewrites the item"
```

Expected: PASS

- [ ] **Step 9: Run the whole gate**

Run: `flutter analyze && flutter test`
Expected: `No issues found!` oraz cały zestaw na zielono. Dwa testy pilnują tu spraw, których nie widać w kodzie: `test/theme_test.dart` — że `_ClipboardEditDialog` nie jest konstruowany z `const`; `test/language_test.dart` (jeśli Task 3 planu English-only już wszedł) — że nie wprowadziliśmy polskich literałów.

- [ ] **Step 10: Run the app and look at it**

Zielony zestaw testów opisuje tylko to, o co go zapytano; dla zmiany wizualnej to za mało.

```bash
flutter run -d macos
```

Sprawdź na oko:
1. otwórz arkusz schowka — ołówek jest na wierszach tekstowych, nie ma go na obrazkowych
2. kliknij ołówek — okno otwiera się z pełną treścią, kursor jest w polu
3. popraw treść, zaznacz kolekcję, `SAVE` — wiersz pokazuje nową treść i **zostaje na swojej pozycji**, nie skacze na górę
4. otwórz ponownie, zmień coś, `CANCEL` — wiersz jest nietknięty, chip też
5. wyczyść pole do zera — `SAVE` jest nieaktywny
6. przełącz motyw w Config na jasny, otwórz okno edycji ponownie — kolory są jasne, nie zostały ciemne

- [ ] **Step 11: Commit**

```bash
git add lib/features/clipboard/presentation/clipboard_history_sheet.dart \
        test/clipboard_history_test.dart
git commit -m "Add an edit dialog for clipboard history entries"
```

---

## Self-review planu

**Pokrycie specu.** Każda sekcja specu ma zadanie: `previewFor` → Task 1; `ClipboardRepository.updateItem` z regułami (`copiedAt`, pusty tekst, obraz, nieznane `id`) → Task 2 (plikowe, z testami) i Task 3 (SQLite); `ClipboardWatcherService.updateItem` → Task 4; ołówek ukryty na obrazach, `_ClipboardEditDialog`, odkładane chipy, zamknięcie po `SAVE` → Task 5. Decyzja 5 specu (angielski, zależność od planu English-only) jest w Global Constraints i w nagłówku Taska 5. Sekcja „Czego ta zmiana nie dotyka" nie generuje zadań z definicji.

**Luka świadomie zostawiona.** `SqliteClipboardRepository.updateItem` nie ma testu automatycznego — żaden test w repozytorium nie konstruuje `AppDatabase`, a dorabianie do tego infrastruktury byłoby większą zmianą niż sama funkcja. Pokrywają go: `flutter analyze`, symetria z przetestowaną wersją plikową i ręczny przebieg z Task 5 Step 10, który idzie właśnie przez SQLite (produkcja używa tej implementacji). Zapisane tutaj, żeby nie wyglądało na przeoczenie.

**Spójność nazw.** `updateItem(String id, {String? text, Set<String>? collections})` — identycznie w interfejsie, obu implementacjach, fake'u testowym i serwisie. `previewFor` i `previewLength` używane w Task 1, 2, 3. `_ClipboardEdit`, `_ClipboardEditDialog`, `_askCollectionName`, `onEdit` — wprowadzone i użyte wyłącznie w Task 5. Tooltip `'Edit entry text'` oraz etykiety `'SAVE'` i `'CANCEL'` to te same łańcuchy w implementacji i w czterech testach. Nazwy kolekcji w testach (`Code`, `Favorites`, `Prompts`, `Important`) zgadzają się z `kDefaultClipboardCollections` z planu English-only.
