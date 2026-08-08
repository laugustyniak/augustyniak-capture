# Edycja wpisów w historii schowka

Data: 2026-08-09 (przeprojektowane po przebudowie arkusza w `cf78b7f`)

## Problem

Historia schowka (`lib/features/clipboard/`) pozwala wkleić wpis, przekazać go
do kolejki, oznaczyć kolekcją i usunąć. Nie pozwala **zmienić jego treści**.
Rzecz skopiowana jest często prawie tym, czego użytkownik chce — z ogonem
białych znaków, zbędną linią, literówką — a jedyną drogą do poprawki jest
wklejenie gdzie indziej, poprawienie i skopiowanie z powrotem, co tworzy drugi
wpis obok pierwszego.

Skutek dotyczy przede wszystkim kolekcji. Zbiór nazwany `Prompts` albo `Code` ma
sens tylko wtedy, gdy to, co w nim leży, nadaje się do użycia bez poprawek. Bez
edycji kolekcja gromadzi surowe zrzuty schowka i przestaje być czymś, z czego
się korzysta.

## Rozwiązanie

Akcja `EDIT` w panelu podglądu zamienia treść wpisu na pole tekstowe **w tym
samym miejscu**. Zmiana zapisuje się przy utracie fokusu i nadpisuje wpis.

### Decyzje

1. **Nadpisanie w miejscu**, nie zapis jako nowy wpis. Historia schowka staje
   się listą rzeczy, które użytkownik chce mieć, a nie dziennikiem tego, co
   dokładnie przeszło przez schowek. Zapisywanie kopii mnożyłoby prawie
   identyczne pozycje obok siebie — dokładnie ten problem, który dziś zmusza do
   obejścia przez wklejenie i ponowne skopiowanie.

2. **Edycja w panelu podglądu, bez okna dialogowego.** Podgląd już renderuje
   całą treść wpisu w przewijanej ramce i już trzyma wszystkie akcje na nim;
   edycja jest kolejną akcją na tym samym obiekcie, a nie osobnym ekranem.
   Okno dialogowe rozważano wcześniej i odrzucono: arkusz jest sam w sobie
   warstwą nad aplikacją, a druga warstwa nad nim to dwa `Escape` do wyjścia z
   poprawienia literówki.

3. **Tryb edycji jest jawny, przełączany akcją `EDIT`** — treść nie jest polem
   tekstowym cały czas. Powód jest klawiaturowy: arkusz nawiguje strzałkami, a
   `Enter` wkleja zaznaczony wpis. Skupione `EditableText` zjada jedno i drugie,
   więc trwale edytowalna treść zabiłaby model sterowania, na którym stoi cały
   arkusz.

4. **Zapis następuje przy utracie fokusu, nie na przycisku.** Nie ma `SAVE`;
   kliknięcie innego wiersza listy zapisuje to, co użytkownik napisał, i
   przechodzi dalej. Alternatywą była stopka `SAVE` / `CANCEL`, ale w edycji w
   miejscu klik w inny wiersz musiałby wtedy albo zostać zignorowany, albo
   wyrzucić tekst — obie odpowiedzi są gorsze od zapisania.

   Bezpiecznikiem jest bursztynowy znacznik **`UNSAVED`** z przyciskiem
   cofnięcia, dokładnie jak w `RecordingEditor` w Kolejce. Bez niego „zapisane,
   gdy odwróciłeś wzrok" i „stracone" wyglądają tak samo. `Escape` wychodzi z
   trybu edycji, wcześniej zapisując.

5. **Zapis nie dotyka schowka systemowego.** Jedna akcja, jeden skutek.
   Porządkowa poprawka wpisu sprzed godziny nie może po cichu podmienić tego, co
   użytkownik ma właśnie skopiowane. Wklejenie pozostaje tam, gdzie było —
   `PASTE ⏎` i `Enter`.

6. **`EDIT` nie pojawia się na wpisach obrazkowych.** Obraz nie ma treści do
   podmiany, a kontrolka, która nic nie robi, jest gorsza niż jej brak — ta sama
   zasada, którą stosuje przycisk routowania w Kolejce (ukryty, nie wyszarzony).

7. **Wszystko po angielsku**, zgodnie z CLAUDE.md i z arkuszem, który został
   przetłumaczony w `cf78b7f`. Wcześniejsza wersja tego specu decydowała
   odwrotnie i uzależniała się od Taska 2 planu `2026-08-09-english-only-strings`
   — obie te rzeczy są nieaktualne.

### Co odpada wraz z oknem dialogowym

Poprzednia wersja specu wkładała do okna chipy kolekcji i wymagała, żeby
zapisywały się dopiero na `SAVE` (okno z `CANCEL`, które część zmian zapisało po
cichu, jest pułapką). Bez okna ten wymóg nie ma przedmiotu: kolekcjami zarządza
osobna akcja `COLLECTIONS` podglądu, która zapisuje natychmiast i nie ma czego
anulować.

Konsekwencja sięga aż do warstwy danych — repozytorium potrzebuje wyłącznie
tekstu, więc metoda nazywa się `updateItemText(id, text)`, a nie
`updateItem(id, {text, collections})`. Nikt nie wołałby drugiego parametru.

### Dlaczego nie ma tu ryzyka pętli sprzężenia zwrotnego

`ClipboardWatcherService` odpytuje schowek co 750 ms i zapisuje jako nowy wpis
każdą treść różną od `_lastText`. Gdyby zapis edycji wstawiał tekst do schowka,
watcher zobaczyłby go jako świeżą kopię i utworzył duplikat własnej edycji —
chyba że `_lastText` zostałoby ustawione ręcznie, tak jak robi to
`copyToClipboard`. Decyzja 5 usuwa ten problem u źródła: skoro edycja nie dotyka
schowka, watcher nie ma czego zobaczyć.

## Architektura

### Domena — `ClipboardItem`

Nowa statyczna funkcja:

```dart
static String previewFor(String text);
```

Zwraca pierwsze 120 znaków zakończone `...`, albo cały tekst gdy krótszy. Dziś
ta reguła jest zapisana inline w `ClipboardWatcherService.checkNow`; edycja jest
drugim miejscem, które musi wyliczyć podgląd, a dwie kopie tej samej reguły
rozjeżdżają się z czasem.

### Dane — `ClipboardRepository`

Nowa metoda w interfejsie, zaimplementowana w obu klasach
(`LocalJsonClipboardRepository` i `SqliteClipboardRepository`):

```dart
Future<void> updateItemText(String id, String text);
```

Reguły identyczne w obu implementacjach:

- **`copiedAt` nigdy się nie zmienia.** To mechanizm realizujący decyzję 1:
  SQLite czyta `ORDER BY copied_at DESC`, więc nietknięty znacznik czasu
  oznacza, że wpis zostaje na swojej pozycji. Odświeżanie go wyrzucałoby każdą
  poprawkę na górę listy.
- **`preview` jest przeliczane** przez `ClipboardItem.previewFor`. Nigdy nie
  przychodzi z zewnątrz.
- **Pusty lub złożony z samych białych znaków tekst jest ignorowany** (metoda
  kończy się bez zapisu). Wpis bez treści nie da się wkleić ani wyszukać —
  wyglądałby na zepsuty wiersz. Usuwanie ma własną akcję.
- **Wpisy typu `image` są ignorowane** — obraz nie ma treści do podmiany.
- Nieznane `id` to ciche no-op, tak jak w istniejącym `toggleItemCollection`.

`toggleItemCollection` zostaje bez zmian.

### Serwis — `ClipboardWatcherService`

```dart
Future<void> updateItemText(String id, String text) async {
  await _repository.updateItemText(id, text);
  notifyListeners();
}
```

Nie dotyka `_lastText`, `_lastImagePath` ani schowka systemowego.

### UI — `clipboard_history_sheet.dart`

**Stan edycji mieszka w `_ClipboardHistorySheetState`, nie w podglądzie.** To
nie jest kwestia gustu: skoro klik w inny wiersz ma *zapisać* rozpoczętą
edycję, arkusz musi umieć wymusić zapis przed zmianą zaznaczenia — a nie da się
tego zrobić, sięgając do stanu widgetu-dziecka. Arkusz trzyma więc
`_editingId`, `_editController` i `_syncedText`, a `_ClipboardPreview` zostaje
bezstanowy i dostaje je z góry. Jest to zarazem ta sama zasada, którą stosuje
`editingId` w `_QueueTabState`.

- `_syncedText` to ostatnia wartość wzięta **z wpisu**. `dirty` jest różnicą
  względem niej — dokładnie jak `_syncedTitle`/`_syncedText` w
  `RecordingEditor`.
- `_commitEdit()` zapisuje tylko gdy tekst jest brudny i nie jest pusty, po
  czym aktualizuje `_syncedText`. Wołane z trzech miejsc: utraty fokusu pola,
  wyjścia z trybu edycji i zmiany zaznaczenia.
- `_revertEdit()` przywraca `_syncedText` do pola.
- Zmiana zaznaczenia (`_ClipboardListRow.onTap`, strzałki) woła
  `_endEdit()` **przed** ustawieniem `_selectedId`.

W `_ClipboardPreview`:

- piąta akcja `EDIT` w stopce, między `TO CAPTURE` a `COLLECTIONS`, renderowana
  tylko dla wpisów tekstowych;
- w trybie edycji ramka treści renderuje `TextField` zamiast `Text`, tą samą
  czcionką `ConsoleFont.mono` i tym samym rozmiarem, żeby treść nie skakała przy
  wejściu w tryb;
- przy `dirty` w nagłówku pojawia się `UNSAVED` plus przycisk cofnięcia;
- pozostałe akcje zostają widoczne i działają — zapis przy utracie fokusu
  oznacza, że nie ma stanu „niezapisane, więc nie wolno".

## Czego ta zmiana nie dotyka

- **`clipboard_fts`** — tabela FTS5 jest tworzona w `app_database.dart`, ale
  nigdy nie zapisywana ani nie odpytywana; wyszukiwanie realizuje Dart w
  `_visibleItems`. Edycja nie ma czego w niej odświeżać.
- **Synchronizacja Turso** — `turso_sync_service.dart` wysyła
  `INSERT OR REPLACE` po `id`, więc zmieniona treść dojedzie na inne urządzenie
  przy następnym sync bez dodatkowej flagi.
- **Schowek systemowy** — patrz decyzja 5.
- **Kolekcje** — patrz „Co odpada wraz z oknem dialogowym".

## Testy

Wszystkie trafiają do `test/clipboard_history_test.dart`. Mimo nazwy
`test/clipboard_test.dart` **nie dotyczy historii schowka** — testuje
`ClipboardSink` w potoku nagrań. CLAUDE.md odnotowuje tę pułapkę wprost.

### Grupa `ClipboardRepository` — czysty Dart, `LocalJsonClipboardRepository`

- edycja tekstu przelicza `preview` oraz zachowuje pozycję wpisu i jego kolekcje
- pusty tekst (oraz złożony z samych spacji) nie zmienia wpisu
- wpis typu `image` jest nietknięty
- zmiana przeżywa ponowne wczytanie repozytorium z dysku
- nieznane `id` nie rzuca i nie zmienia listy

Fake `_MemoryClipboardRepository` w tym samym pliku implementuje
`ClipboardRepository`, więc rozszerzenie interfejsu zepsuje jego kompilację,
dopóki nie dostanie własnego `updateItemText`. Jest to pożądane — kompilator nie
pozwoli przeoczyć żadnej implementacji.

### Grupa widgetowa

- `EDIT` jest w podglądzie wpisu tekstowego i nie ma go dla obrazkowego
- `EDIT` zamienia treść na pole; wpisanie tekstu i utrata fokusu zapisuje
- **wybranie innego wiersza w trakcie edycji zapisuje, a nie porzuca** — to test
  pilnujący decyzji 4 i jedyny, który odróżnia ją od stopki `SAVE`/`CANCEL`
- brudne pole pokazuje `UNSAVED`, a cofnięcie przywraca pierwotny tekst
- pusta treść nie nadpisuje wpisu

**Pułapka:** pole edycji jest skupiane po wejściu w tryb, a migający kursor to
animacja bez końca — `pumpAndSettle` zawiesi się do timeoutu. Nowe testy używają
`pump()` z jawnym czasem. CLAUDE.md wymienia tę zasadę w sekcji Testing.

Każdy nowy test należy zobaczyć na czerwono przed wprowadzeniem poprawki.
