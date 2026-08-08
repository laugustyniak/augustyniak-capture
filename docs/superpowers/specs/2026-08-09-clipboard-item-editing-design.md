# Edycja wpisów w historii schowka

Data: 2026-08-09

## Problem

Historia schowka (`lib/features/clipboard/`) pozwala skopiować wpis, oznaczyć go
kolekcją, usunąć i przekazać do przetworzenia przez LLM. Nie pozwala **zmienić
jego treści**. Rzecz skopiowana jest często prawie tym, czego użytkownik chce —
z ogonem białych znaków, zbędną linią, literówką — a jedyną drogą do poprawki
jest wklejenie gdzie indziej, poprawienie i skopiowanie z powrotem, co tworzy
drugi wpis obok pierwszego.

Skutek dotyczy przede wszystkim kolekcji. Zbiór nazwany `Prompty` albo `Kod` ma
sens tylko wtedy, gdy to, co w nim leży, nadaje się do użycia bez poprawek.
Bez edycji kolekcja gromadzi surowe zrzuty schowka i przestaje być czymś, z
czego się korzysta.

## Rozwiązanie

Ołówek na wierszu tekstowym otwiera okno z pełną treścią wpisu i jego
kolekcjami. `ZAPISZ` nadpisuje wpis w miejscu.

### Decyzje przyjęte w trakcie projektowania

1. **Nadpisanie w miejscu**, nie zapis jako nowy wpis. Historia schowka staje
   się listą rzeczy, które użytkownik chce mieć, a nie dziennikiem tego, co
   dokładnie przeszło przez schowek. Zapisywanie kopii mnożyłoby prawie
   identyczne pozycje obok siebie — dokładnie ten problem, który dziś zmusza do
   obejścia przez wklejenie i ponowne skopiowanie.
2. **Osobne okno dialogowe**, nie edycja w wierszu. Arkusz schowka jest
   sterowany klawiaturą (`↑` `↓` `Enter`, pole szukania z `autofocus`); pole
   tekstowe w wierszu przechwyciłoby te klawisze, a długi wpis rozepchnąłby
   listę.
3. **`ZAPISZ` nie dotyka schowka systemowego.** Jedna akcja, jeden skutek.
   Porządkowa poprawka wpisu sprzed godziny nie może po cichu podmienić tego, co
   użytkownik ma właśnie skopiowane. Wklejenie pozostaje tam, gdzie było —
   kliknięcie wiersza (`_selectAndCopy`).
4. **Ołówka nie ma na wpisach obrazkowych.** Obraz nie ma treści do podmiany, a
   kontrolka, która nic nie robi, jest gorsza niż jej brak — ta sama zasada,
   którą stosuje przycisk routowania w Kolejce (ukryty, nie wyszarzony).
5. **Nowe okno jest po angielsku**, zgodnie z CLAUDE.md i z docelowym stanem
   pliku, w którym mieszka.

   Pierwotnie zdecydowano odwrotnie — cały feature `clipboard` powstał po
   polsku (`SCHOWEK SYSTEMOWY`, `Wyczyszcz`, `NOWA KOLEKCJA`), a `EDIT ENTRY`
   obok `Wyczyszcz` w jednym arkuszu wyglądałby na niedokończony. Przesłanka
   przestała obowiązywać: równolegle powstał zatwierdzony plan
   `docs/superpowers/plans/2026-08-09-english-only-strings.md`, którego Task 2
   tłumaczy ten arkusz w całości, a Task 3 dodaje `test/language_test.dart`
   blokujący polskie literały w `lib/`. Polski w tym arkuszu jest więc długiem
   z terminem spłaty, a nie stanem docelowym — argument „dopasuj się do pliku"
   wskazuje teraz na angielski.

   **Ta zmiana zależy od Taska 2 tamtego planu i wchodzi po nim.** Poza
   językiem daje to jeszcze jedno: okno czyta stałą
   `kDefaultClipboardCollections` zamiast dopisywać trzecią kopię listy
   domyślnych kolekcji.

### Dlaczego nie ma tu ryzyka pętli sprzężenia zwrotnego

`ClipboardWatcherService` odpytuje schowek co 750 ms i zapisuje jako nowy wpis
każdą treść różną od `_lastText`. Gdyby zapis edycji wstawiał tekst do schowka,
watcher zobaczyłby go jako świeżą kopię i utworzył duplikat własnej edycji —
chyba że `_lastText` zostałoby ustawione ręcznie, tak jak robi to
`copyToClipboard`. Decyzja 3 usuwa ten problem u źródła: skoro edycja nie dotyka
schowka, watcher nie ma czego zobaczyć. Jest to powód, dla którego wariant
„zapisz i skopiuj" byłby istotnie droższy niż wygląda.

## Architektura

### Domena — `ClipboardItem`

Nowa statyczna funkcja:

```dart
static String previewFor(String text);
```

Zwraca pierwsze 120 znaków zakończone `...`, albo cały tekst gdy krótszy. Dziś
ta reguła jest zapisana inline w `ClipboardWatcherService.checkNow`
(`clipboard_watcher_service.dart:124`). Edycja jest drugim miejscem, które musi
wyliczyć podgląd; dwie kopie tej samej reguły rozjeżdżają się z czasem, więc
watcher przechodzi na wspólną funkcję zamiast liczyć po swojemu.

Sama klasa nie zmienia się poza tym — jest `@immutable` i ma `copyWith`.

### Dane — `ClipboardRepository`

Nowa metoda w interfejsie, zaimplementowana w obu klasach
(`LocalJsonClipboardRepository` i `SqliteClipboardRepository`):

```dart
Future<void> updateItem(String id, {String? text, Set<String>? collections});
```

`null` znaczy „nie ruszaj tego pola". Reguły identyczne w obu implementacjach:

- **`copiedAt` nigdy się nie zmienia.** To mechanizm realizujący decyzję 1:
  SQLite czyta `ORDER BY copied_at DESC`, więc nietknięty znacznik czasu
  oznacza, że wpis zostaje na swojej pozycji. Odświeżanie go wyrzucałoby każdą
  poprawkę na górę listy.
- **`preview` jest przeliczane** przez `ClipboardItem.previewFor` zawsze, gdy
  podano `text`. Nigdy nie przychodzi z zewnątrz.
- **Pusty lub złożony z samych białych znaków `text` jest ignorowany** (metoda
  kończy się bez zapisu). Wpis bez treści nie da się skopiować ani wyszukać —
  wyglądałby na zepsuty wiersz. Usuwanie ma własny przycisk.
- **Wpisy typu `image` ignorują `text`**; `collections` działa dla nich
  normalnie.
- Nieznane `id` to ciche no-op, tak jak w istniejącym `toggleItemCollection`.

`toggleItemCollection` zostaje bez zmian — obsługuje ikonę zakładki na wierszu,
która działa natychmiastowo i nie ma czego anulować.

Implementacja SQLite wykonuje jedno `UPDATE clipboard_items SET ... WHERE id = ?`
i kończy przez `getItems()`, tak jak pozostałe metody mutujące w tej klasie.
Implementacja JSON podmienia element listy przez `copyWith` i wywołuje `_save()`.

### Serwis — `ClipboardWatcherService`

```dart
Future<void> updateItem(String id, {String? text, Set<String>? collections}) async {
  await _repository.updateItem(id, text: text, collections: collections);
  notifyListeners();
}
```

Nic więcej. Nie dotyka `_lastText`, `_lastImagePath` ani schowka systemowego.

### UI — `clipboard_history_sheet.dart`

`_ClipboardItemTile` dostaje nullowalne `onEdit`. Ikona ołówka renderuje się
tylko gdy `onEdit != null`; arkusz podaje callback wyłącznie dla wpisów
`ClipboardItemType.text`. Pozycja w rzędzie akcji: przed ✨ (edycja jest tańsza
i częstsza niż wysłanie do LLM), przed zakładką i przed usunięciem.

Nowy prywatny widget `_ClipboardEditDialog` w tym samym pliku:

- wielolinijkowe `TextField` z czcionką `ConsoleFont.mono` — tą samą, którą
  podgląd używa w wierszu, żeby treść nie zmieniała kroju przy wejściu w edycję;
  `autofocus: true`, bo cały sens funkcji to szybka poprawka
- rząd chipów kolekcji z tą samą listą sugestii co `_manageItemCollections` —
  stała `kDefaultClipboardCollections` unia `watcherService.allCollections` —
  oraz chip `+` otwierający prompt o nazwę nowej kolekcji
- `CANCEL` / `SAVE`; `SAVE` nieaktywny, gdy pole jest puste po przycięciu
  białych znaków
- Escape zamyka okno jak `CANCEL`
- `SAVE` zamyka okno i wraca do arkusza schowka; arkusz pozostaje otwarty z
  zachowanym wyszukiwaniem i wybraną kolekcją

**Wszystkie zmiany są odkładane i zapisują się dopiero na `ZAPISZ`** — łącznie z
chipami kolekcji. Jest to świadome odstępstwo od reguły „chip zapisuje się na
dotknięcie", którą stosuje `RecordingEditor` w Kolejce. Tamten edytor nie ma
przycisku anulowania i dlatego może zapisywać na bieżąco; ten ma. Okno z
`ANULUJ`, które część zmian już po cichu zapisało, jest pułapką: użytkownik
klika „anuluj" i połowa zostaje. Dialog trzyma więc własną kopię tekstu i
własny `Set<String>` kolekcji, a `ANULUJ` porzuca obie. Zapis to jedno wywołanie
`watcherService.updateItem(id, text: ..., collections: ...)`.

Chip `+` w dialogu dopisuje nazwę do odłożonego zbioru, a nie do wpisu —
w odróżnieniu od istniejącego `_promptNewCollection`, który zmienia jedynie
aktywny filtr arkusza.

## Czego ta zmiana nie dotyka

- **`clipboard_fts`** — tabela FTS5 jest tworzona w `app_database.dart:67`, ale
  nigdy nie zapisywana ani nie odpytywana; wyszukiwanie w arkuszu realizuje Dart
  w `filteredItems`. Edycja nie ma czego w niej odświeżać.
- **Synchronizacja Turso** — `turso_sync_service.dart:138` wysyła
  `INSERT OR REPLACE` po `id`, więc zmieniona treść dojedzie na inne urządzenie
  przy następnym sync bez dodatkowej flagi ani znacznika.
- **Schowek systemowy** — patrz decyzja 3.

## Testy

Wszystkie testy trafiają do `test/clipboard_history_test.dart`. Mimo nazwy
`test/clipboard_test.dart` **nie dotyczy historii schowka** — testuje
`ClipboardSink` w potoku nagrań (czy ukończona transkrypcja trafia do schowka
systemowego) i nie ma z tą zmianą nic wspólnego.

### Grupa `ClipboardRepository` — czysty Dart, `LocalJsonClipboardRepository`

- edycja tekstu przelicza `preview` oraz zachowuje pozycję wpisu na liście i
  jego kolekcje
- pusty tekst (oraz złożony z samych spacji) nie zmienia wpisu
- `text` przekazany dla wpisu typu `image` jest ignorowany, a `collections`
  w tym samym wywołaniu zostaje zapisane
- zmiana przeżywa ponowne wczytanie repozytorium z dysku
- `updateItem` z nieznanym `id` nie rzuca i nie zmienia listy

Fake `_MemoryClipboardRepository` w tym samym pliku (`clipboard_history_test.dart:337`)
implementuje `ClipboardRepository`, więc rozszerzenie interfejsu zepsuje jego
kompilację, dopóki nie dostanie własnego `updateItem`. Jest to pożądane —
kompilator nie pozwoli przeoczyć żadnej implementacji.

### Grupa widgetowa

- ołówek jest obecny na wierszu tekstowym i nieobecny na obrazkowym
- edycja treści i `ZAPISZ` zmienia wpis widoczny w arkuszu
- `ANULUJ` nie zmienia ani tekstu, ani kolekcji — test pilnujący decyzji o
  odkładaniu zmian

**Pułapka do przestrzegania:** dialog ma `autofocus`, a migający kursor to
animacja bez końca, więc `pumpAndSettle` zawiesi się do timeoutu. Nowe testy
używają `pump()` z jawnym czasem. CLAUDE.md wymienia tę zasadę w sekcji Testing;
ten dialog dokłada się do listy widgetów, których nie wolno „ustabilizować".

Każdy nowy test należy zobaczyć na czerwono przed wprowadzeniem poprawki, a nie
tylko na zielono po niej.
