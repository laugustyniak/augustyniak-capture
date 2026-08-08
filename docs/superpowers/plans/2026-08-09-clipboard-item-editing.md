# Edycja wpisów w historii schowka — plan wdrożenia

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ołówek na tekstowym wpisie historii schowka otwiera okno, w którym można poprawić treść i przypisać kolekcje; zapis nadpisuje wpis w miejscu.

**Architecture:** Nowa metoda `updateItem` w interfejsie `ClipboardRepository` (dwie implementacje: plikowa i SQLite) przechodzi przez cienkie `ClipboardWatcherService.updateItem` do nowego dialogu `_ClipboardEditDialog`. Dialog trzyma odłożoną kopię tekstu i kolekcji i zapisuje wszystko jednym wywołaniem dopiero na `ZAPISZ`; znacznik `copiedAt` nigdy się nie zmienia, dzięki czemu wpis zostaje na swojej pozycji na liście.

**Tech Stack:** Flutter / Dart 3.10, `sqlite3`, `flutter_test`. Bez nowych zależności.

**Spec:** `docs/superpowers/specs/2026-08-09-clipboard-item-editing-design.md`

## Global Constraints

- **Teksty widoczne dla użytkownika w feature `clipboard` piszemy po polsku** — cały ten feature jest po polsku (`SCHOWEK SYSTEMOWY`, `Wyczyszcz`, `NOWA KOLEKCJA`) i mieszanie języków w jednym arkuszu wyglądałoby na niedokończone. To świadome odstępstwo od reguły CLAUDE.md o angielskich stringach, zapisane w specu jako decyzja 5.
- **Żaden widget malujący paletę `Console` nie może mieć konstruktora `const` ani być konstruowany z `const`.** `test/theme_test.dart:302` skanuje `lib/` regexem `const _Widget(` i zgłosi każde takie miejsce jako błąd. Powód: Flutter pomija przebudowę widgetu identycznego z poprzednim, więc `const` przypina stary motyw po przełączeniu.
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
- Produces: `static String ClipboardItem.previewFor(String text)` — zwraca `text`, gdy `text.length <= 120`, w przeciwnym razie pierwsze 120 znaków sklejone z `'...'`

- [ ] **Step 1: Write the failing test**

W `test/clipboard_history_test.dart`, wewnątrz istniejącej grupy `group('ClipboardItem', ...)`, dopisz po teście `serialization roundtrip with collections`:

```dart
    test('previewFor shortens long text and passes short text through', () {
      expect(ClipboardItem.previewFor('krótki tekst'), 'krótki tekst');

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
  /// Skrót treści pokazywany na wierszu listy.
  ///
  /// Jedyna definicja tej reguły — liczą z niej zarówno watcher zapisujący
  /// nowy wpis, jak i edycja nadpisująca istniejący. Dwie kopie rozjechałyby
  /// się przy pierwszej zmianie limitu.
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
git commit -m "Wyciągnij regułę podglądu schowka do ClipboardItem.previewFor"
```

---

### Task 2: `updateItem` w interfejsie i w repozytorium plikowym

**Files:**
- Modify: `lib/features/clipboard/data/clipboard_repository.dart` (interfejs `ClipboardRepository` + `LocalJsonClipboardRepository`)
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
      await repository.addItem(_textItem('1', 'Pierwszy'));
      await repository.addItem(_textItem('2', 'Drugi'));
      await repository.toggleItemCollection('2', 'Kod');

      final DateTime originalCopiedAt = repository.items
          .firstWhere((ClipboardItem item) => item.id == '2')
          .copiedAt;

      await repository.updateItem('2', text: 'Drugi, poprawiony');

      // Pozycja: '2' był najnowszy, więc zostaje na indeksie 0.
      expect(repository.items.map((ClipboardItem item) => item.id),
          <String>['2', '1']);

      final ClipboardItem edited = repository.items.first;
      expect(edited.text, 'Drugi, poprawiony');
      expect(edited.preview, 'Drugi, poprawiony');
      expect(edited.collections, <String>{'Kod'});
      expect(edited.copiedAt, originalCopiedAt);
    });

    test('editing recomputes preview for long text', () async {
      await repository.initialize();
      await repository.addItem(_textItem('1', 'krótko'));

      final String long = 'z' * 200;
      await repository.updateItem('1', text: long);

      expect(repository.items.single.text, long);
      expect(repository.items.single.preview, '${'z' * 120}...');
    });

    test('blank text leaves the item untouched', () async {
      await repository.initialize();
      await repository.addItem(_textItem('1', 'Oryginał'));

      await repository.updateItem('1', text: '');
      expect(repository.items.single.text, 'Oryginał');

      await repository.updateItem('1', text: '   \n  ');
      expect(repository.items.single.text, 'Oryginał');
    });

    test('an image ignores text but accepts collections', () async {
      await repository.initialize();
      await repository.addItem(_imageItem('img', '${tempDir.path}/a.png'));

      await repository.updateItem(
        'img',
        text: 'to nie ma prawa wejść',
        collections: <String>{'Ulubione'},
      );

      final ClipboardItem item = repository.items.single;
      expect(item.text, isNull);
      expect(item.collections, <String>{'Ulubione'});
    });

    test('collections are replaced wholesale, not merged', () async {
      await repository.initialize();
      await repository.addItem(_textItem('1', 'Tekst'));
      await repository.toggleItemCollection('1', 'Kod');

      await repository.updateItem('1', collections: <String>{'Prompty'});

      expect(repository.items.single.collections, <String>{'Prompty'});
    });

    test('an unknown id is a silent no-op', () async {
      await repository.initialize();
      await repository.addItem(_textItem('1', 'Tekst'));

      await repository.updateItem('nie-ma-takiego', text: 'cokolwiek');

      expect(repository.items, hasLength(1));
      expect(repository.items.single.text, 'Tekst');
    });

    test('an edit survives reloading the repository from disk', () async {
      await repository.initialize();
      await repository.addItem(_textItem('1', 'Przed'));
      await repository.updateItem(
        '1',
        text: 'Po',
        collections: <String>{'Ważne'},
      );

      final LocalJsonClipboardRepository restored = LocalJsonClipboardRepository(
        maxItems: 3,
        storageDirectoryProvider: () async => tempDir,
      );
      await restored.initialize();

      expect(restored.items.single.text, 'Po');
      expect(restored.items.single.collections, <String>{'Ważne'});
    });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/clipboard_history_test.dart`
Expected: FAIL — błąd kompilacji `The method 'updateItem' isn't defined for the type 'ClipboardRepository'`.

- [ ] **Step 3: Add the method to the interface and the file-backed implementation**

W `lib/features/clipboard/data/clipboard_repository.dart` dopisz do `abstract class ClipboardRepository`, między `addItem` a `toggleItemCollection`:

```dart
  /// Nadpisuje wpis w miejscu. `null` znaczy „nie ruszaj tego pola".
  ///
  /// `copiedAt` nigdy się nie zmienia — dzięki temu poprawka nie wyrzuca wpisu
  /// na górę listy. Pusty `text` oraz `text` dla wpisu obrazkowego są
  /// ignorowane.
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
    throw UnimplementedError('Task 3 tego planu dostarcza implementację.');
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
git commit -m "Dodaj ClipboardRepository.updateItem i implementację plikową"
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

    // copied_at zostaje nietknięte: getItems() czyta ORDER BY copied_at DESC,
    // więc wpis zostaje na swojej pozycji na liście.
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
git commit -m "Zaimplementuj updateItem w repozytorium SQLite schowka"
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
      await repository.addItem(_textItem('1', 'Przed'));
      final _FakeClipboardGateway gateway = _FakeClipboardGateway();
      final ClipboardWatcherService service = ClipboardWatcherService(
        repository: repository,
        gateway: gateway,
      );

      int notifications = 0;
      service.addListener(() => notifications++);

      await service.updateItem(
        '1',
        text: 'Po',
        collections: <String>{'Kod'},
      );

      expect(repository.items.single.text, 'Po');
      expect(repository.items.single.collections, <String>{'Kod'});
      expect(notifications, 1);
      // Zapis edycji nie może podmienić tego, co użytkownik ma w schowku.
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
  /// Nadpisuje wpis w miejscu.
  ///
  /// Świadomie nie dotyka `_lastText` ani `_lastImagePath`: edycja nie wstawia
  /// niczego do schowka systemowego, więc watcher nie ma czego zobaczyć przy
  /// następnym odpytaniu i nie powstaje duplikat własnej edycji.
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
git commit -m "Dodaj ClipboardWatcherService.updateItem"
```

---

### Task 5: Ołówek na wierszu i okno edycji

Największe zadanie i jedyne z widoczną zmianą. Kończy się ręcznym uruchomieniem aplikacji — dla zmiany wizualnej zielony test opisuje tylko to, o co go zapytano, a CLAUDE.md zapisuje przypadek, w którym pełny zestaw testów przeszedł nad zepsutym wyglądem.

**Files:**
- Modify: `lib/features/clipboard/presentation/clipboard_history_sheet.dart`
- Test: `test/clipboard_history_test.dart` (grupa `ClipboardWatcherService & Sheet Widget`)

**Interfaces:**
- Consumes: `ClipboardWatcherService.updateItem` z Task 4, `ClipboardWatcherService.allCollections` (istnieje)
- Produces: prywatne dla pliku — `_ClipboardEdit`, `_ClipboardEditDialog`, `_askCollectionName`; `_ClipboardItemTile` dostaje pole `final VoidCallback? onEdit`

- [ ] **Step 1: Write the failing tests**

W `test/clipboard_history_test.dart`, wewnątrz `group('ClipboardWatcherService & Sheet Widget', ...)`, dopisz:

```dart
    testWidgets('the pencil is on text rows and absent on image rows', (
      WidgetTester tester,
    ) async {
      final _MemoryClipboardRepository repository = _MemoryClipboardRepository();
      await repository.addItem(_imageItem('img', '/tmp/nie-istnieje.png'));
      await repository.addItem(_textItem('txt', 'Tekst do poprawki'));
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

      // Dwa wiersze na liście, ale tylko tekstowy ma ołówek.
      expect(find.byTooltip('Edytuj treść wpisu'), findsOneWidget);

      service.dispose();
    });

    testWidgets('saving an edit rewrites the item', (
      WidgetTester tester,
    ) async {
      final _MemoryClipboardRepository repository = _MemoryClipboardRepository();
      await repository.addItem(_textItem('1', 'Przed poprawką'));
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

      await tester.tap(find.byTooltip('Edytuj treść wpisu'));
      await tester.pump(const Duration(milliseconds: 300));

      final Finder dialogField = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      expect(dialogField, findsOneWidget);

      await tester.enterText(dialogField, 'Po poprawce');
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(FilterChip, 'Kod'),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('ZAPISZ'));
      await tester.pump(const Duration(milliseconds: 300));

      expect(repository.items.single.text, 'Po poprawce');
      expect(repository.items.single.collections, <String>{'Kod'});
      expect(find.byType(AlertDialog), findsNothing);

      service.dispose();
    });

    testWidgets('cancelling discards both the text and the collections', (
      WidgetTester tester,
    ) async {
      final _MemoryClipboardRepository repository = _MemoryClipboardRepository();
      await repository.addItem(_textItem('1', 'Nietknięte'));
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

      await tester.tap(find.byTooltip('Edytuj treść wpisu'));
      await tester.pump(const Duration(milliseconds: 300));

      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        'To ma zniknąć',
      );
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(FilterChip, 'Kod'),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('ANULUJ'));
      await tester.pump(const Duration(milliseconds: 300));

      expect(repository.items.single.text, 'Nietknięte');
      expect(repository.items.single.collections, isEmpty);

      service.dispose();
    });

    testWidgets('an empty edit cannot be saved', (WidgetTester tester) async {
      final _MemoryClipboardRepository repository = _MemoryClipboardRepository();
      await repository.addItem(_textItem('1', 'Coś'));
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

      await tester.tap(find.byTooltip('Edytuj treść wpisu'));
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
        find.widgetWithText(ElevatedButton, 'ZAPISZ'),
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
/// Pyta o nazwę kolekcji i zwraca ją, albo `null` gdy użytkownik zrezygnował.
///
/// Wspólna dla paska kolekcji w arkuszu i dla okna edycji — te dwa miejsca
/// robią z odpowiedzią co innego, ale pytają dokładnie o to samo.
Future<String?> _askCollectionName(BuildContext context) {
  final TextEditingController nameController = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (BuildContext context) => ConsolePaletteScope(
      builder: (BuildContext context) => AlertDialog(
        backgroundColor: Console.surface,
        title: Text(
          'NOWA KOLEKCJA',
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
            hintText: 'Nazwa kolekcji (np. Prompty, Kod)...',
            hintStyle: TextStyle(color: Console.dimText),
            filled: true,
            fillColor: Console.surfaceRaised,
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('Anuluj', style: TextStyle(color: Console.dimText)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Console.accent),
            onPressed: () {
              final String text = nameController.text.trim();
              if (text.isNotEmpty) {
                Navigator.of(context).pop(text);
              }
            },
            child: Text('Dodaj', style: TextStyle(color: Console.ink)),
          ),
        ],
      ),
    ),
  );
}
```

Następnie zastąp całe ciało istniejącej metody `_promptNewCollection` (linie 186–237) przez:

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
/// Odłożony wynik edycji — to, co dialog zwraca po `ZAPISZ`.
class _ClipboardEdit {
  _ClipboardEdit({required this.text, required this.collections});

  final String text;
  final Set<String> collections;
}

/// Okno edycji pojedynczego wpisu schowka.
///
/// Wszystkie zmiany, łącznie z chipami kolekcji, są odkładane i zapisują się
/// dopiero na `ZAPISZ`. Jest to celowe odstępstwo od reguły „chip zapisuje się
/// na dotknięcie" z `RecordingEditor`: tamten edytor nie ma przycisku
/// anulowania, a ten ma, więc okno, które część zmian zapisało po cichu, byłoby
/// pułapką.
///
/// Konstruktor nie jest `const` i nie wolno go takim uczynić — widget maluje
/// paletę `Console`, a `const` przypiąłby stary motyw po przełączeniu
/// (patrz `test/theme_test.dart`).
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
        'EDYTUJ WPIS',
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
                'KOLEKCJE',
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
                    label: const Text('Nowa'),
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
          child: Text('ANULUJ', style: TextStyle(color: Console.dimText)),
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
          child: Text('ZAPISZ', style: TextStyle(color: Console.ink)),
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
            'Ulubione',
            'Kod',
            'Prompty',
            'Ważne',
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

- [ ] **Step 6: Give the tile a pencil**

W klasie `_ClipboardItemTile` dodaj pole i parametr konstruktora. Konstruktor:

```dart
  const _ClipboardItemTile({
    required this.item,
    required this.timeLabel,
    required this.isSelected,
    required this.onTap,
    this.onConvertToCapture,
    this.onEdit,
    required this.onAddCollection,
    required this.onDelete,
  });
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
                                  message: 'Edytuj treść wpisu',
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

Ołówka nie ma na wpisach obrazkowych, bo obraz nie ma treści do podmiany —
kontrolka, która nic nie robi, jest gorsza niż jej brak.

- [ ] **Step 7: Run tests to verify they pass**

Run: `flutter test test/clipboard_history_test.dart`
Expected: PASS — cztery nowe testy widgetowe plus wszystkie wcześniejsze.

- [ ] **Step 8: Prove the tests are not vacuous**

Skopiuj plik do scratchpada, zepsuj implementację, sprawdź czerwień, przywróć. **Nie używaj `git checkout -- <plik>`** — w brudnym drzewie cofa do `HEAD` i zabiera ze sobą wszystkie inne niezacommitowane zmiany w tym pliku.

```bash
cp lib/features/clipboard/presentation/clipboard_history_sheet.dart /tmp/sheet.bak
```

Zmień w `_editItem` `if (edit == null) return;` na `return;` (czyli zapis nigdy nie następuje) i uruchom:

```bash
flutter test test/clipboard_history_test.dart --plain-name "saving an edit rewrites the item"
```

Expected: FAIL — `Expected: 'Po poprawce' / Actual: 'Przed poprawką'`. Test, który nigdy nie był czerwony, jest założeniem, a nie sprawdzeniem.

```bash
cp /tmp/sheet.bak lib/features/clipboard/presentation/clipboard_history_sheet.dart
flutter test test/clipboard_history_test.dart --plain-name "saving an edit rewrites the item"
```

Expected: PASS

- [ ] **Step 9: Run the whole gate**

Run: `flutter analyze && flutter test`
Expected: `No issues found!` oraz cały zestaw na zielono. `test/theme_test.dart` musi przejść — to on pilnuje, że `_ClipboardEditDialog` nie jest konstruowany z `const`.

- [ ] **Step 10: Run the app and look at it**

Zielony zestaw testów opisuje tylko to, o co go zapytano; dla zmiany wizualnej to za mało.

```bash
flutter run -d macos
```

Sprawdź na oko:
1. otwórz arkusz schowka — ołówek jest na wierszach tekstowych, nie ma go na obrazkowych
2. kliknij ołówek — okno otwiera się z pełną treścią, kursor jest w polu
3. popraw treść, zaznacz kolekcję, `ZAPISZ` — wiersz pokazuje nową treść i **zostaje na swojej pozycji**, nie skacze na górę
4. otwórz ponownie, zmień coś, `ANULUJ` — wiersz jest nietknięty, chip też
5. wyczyść pole do zera — `ZAPISZ` jest nieaktywny
6. przełącz motyw w Config na jasny, otwórz okno edycji ponownie — kolory są jasne, nie zostały ciemne

- [ ] **Step 11: Commit**

```bash
git add lib/features/clipboard/presentation/clipboard_history_sheet.dart \
        test/clipboard_history_test.dart
git commit -m "Dodaj okno edycji wpisu w historii schowka"
```

---

## Self-review planu

**Pokrycie specu.** Każda sekcja specu ma zadanie: `previewFor` → Task 1; `ClipboardRepository.updateItem` z regułami (`copiedAt`, pusty tekst, obraz, nieznane `id`) → Task 2 (plikowe, z testami) i Task 3 (SQLite); `ClipboardWatcherService.updateItem` → Task 4; ołówek ukryty na obrazach, `_ClipboardEditDialog`, odkładane chipy, zamknięcie po `ZAPISZ` → Task 5. Sekcja „Czego ta zmiana nie dotyka" nie generuje zadań z definicji.

**Luka świadomie zostawiona.** `SqliteClipboardRepository.updateItem` nie ma testu automatycznego — żaden test w repozytorium nie konstruuje `AppDatabase`, a dorabianie do tego infrastruktury byłoby większą zmianą niż sama funkcja. Pokrywają go: `flutter analyze`, symetria z przetestowaną wersją plikową i ręczny przebieg z Task 5 Step 10, który idzie właśnie przez SQLite (produkcja używa tej implementacji). Zapisane tutaj, żeby nie wyglądało na przeoczenie.

**Spójność nazw.** `updateItem(String id, {String? text, Set<String>? collections})` — identycznie w interfejsie, obu implementacjach, fake'u testowym i serwisie. `previewFor` i `previewLength` używane w Task 1, 2, 3. `_ClipboardEdit`, `_ClipboardEditDialog`, `_askCollectionName`, `onEdit` — wprowadzone i użyte wyłącznie w Task 5. Tooltip `'Edytuj treść wpisu'` jest tym samym łańcuchem w implementacji i w trzech testach.
