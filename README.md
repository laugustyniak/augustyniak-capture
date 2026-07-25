# Voice Notes — Phase 1

Minimalna aplikacja Flutter do nagrywania notatek głosowych w modelu **offline-first**.

## Gwarancja kolejności

Każdy sposób dodania pozycji — nagranie z mikrofonu, notatka tekstowa i (w
kolejnych fazach) plik audio, zdjęcie, wideo — wykonuje dokładnie tę samą
kolejność:

1. tworzy materiał źródłowy (nagranie do `.m4a`, treść notatki do `.txt`),
2. zatrzymuje recorder / kończy zapis pliku,
3. sprawdza, czy plik istnieje i ma niezerowy rozmiar,
4. zapisuje metadane atomowo do `recordings.json`,
5. dopiero wtedy ustawia status „w kolejce”,
6. uruchamia przetwarzanie właściwe dla typu (transkrypcja, przepisanie treści),
7. błąd przetwarzania nigdy nie usuwa materiału źródłowego.

Procesor **wyłącznie czyta** plik źródłowy — nigdy go nie zmienia ani nie kasuje.

## Funkcje

- nagrywanie AAC/M4A, mono, 16 kHz (parametry edytowalne w zakładce Config),
- notatki tekstowe zapisywane jako `.txt` w tym samym potoku co nagrania,
- lokalny zapis w katalogu dokumentów aplikacji,
- wspólna lista wszystkich pozycji z ikoną i kartą zależną od typu,
- trwałe statusy przetwarzania,
- ponawianie nieudanego przetwarzania,
- adapter HTTP gotowy pod Whisper/OpenAI/Hugging Face,
- brak funkcji usuwania w MVP, aby ograniczyć ryzyko utraty danych.

### Typy pozycji

| Typ | Rozszerzenie | Przetwarzanie | Status |
| --- | --- | --- | --- |
| nagranie z mikrofonu | `.m4a` | transkrypcja przez aktywny profil | działa |
| notatka tekstowa | `.txt` | przepisanie treści (bez sieci) | działa |
| plik audio | oryginalne | transkrypcja przez aktywny profil | zaplanowane |
| obraz | `.jpg`/`.png` | OCR offline | zaplanowane |
| wideo | `.mp4`/`.mov` | ścieżka audio → transkrypcja | zaplanowane |

Typy zaplanowane mają już model i zapis na dysku; ich procesory zgłaszają na
razie „niedostępne”, więc pozycja kończy się czytelnym błędem, nigdy awarią.

## Start

Repo zawiera kod aplikacji, ale katalogi platformowe najlepiej uzupełnić lokalnym Flutter SDK:

```bash
flutter create --platforms=android,ios .
flutter pub get
flutter run
```

Polecenie `flutter create .` zachowa pliki w `lib/`, a wygeneruje pełne pliki Gradle/Xcode wymagane przez lokalną wersję Fluttera.

## Włączenie endpointu Whisper

W `lib/features/recordings/presentation/recordings_page.dart` zamień:

```dart
transcriptionService: const DisabledTranscriptionService(),
```

na przykład na:

```dart
transcriptionService: HttpWhisperTranscriptionService(
  endpoint: Uri.parse('https://twoj-endpoint.example/transcribe'),
  bearerToken: const String.fromEnvironment('TRANSCRIPTION_TOKEN'),
),
```

Uruchomienie z tokenem:

```bash
flutter run --dart-define=TRANSCRIPTION_TOKEN=sekret
```

Oczekiwana odpowiedź endpointu:

```json
{"text": "Treść transkrypcji"}
```

Endpoint powinien przyjmować `multipart/form-data` z polem `file`.

## Zakładki

Aplikacja ma cztery zakładki w dolnej nawigacji:

| Zakładka | Do czego służy |
| --- | --- |
| **Queue** | lista wszystkich pozycji, filtry statusu, wyszukiwarka, przyciski nagrywania i notatki, odtwarzanie |
| **Models** | profile providerów transkrypcji: dodawanie, edycja, usuwanie, wybór aktywnego |
| **Logs** | strumień zdarzeń potoku (zapis, kolejka, transkrypcja, błędy), filtr poziomu |
| **Config** | parametry nagrywania, podsumowanie aktywnego providera, informacje o plikach |

### Models — profile providerów

Zamiast edycji kodu wystarczy dodać profil w zakładce Models. Gotowe presety:
OpenAI Whisper, OpenAI GPT-4o transcribe, Groq, lokalny whisper.cpp
(`http://localhost:8080/inference`) oraz własny endpoint.

Aktywny jest zawsze jeden profil. Brak profilu = transkrypcja wyłączona
(nagrywanie i zapis lokalny działają bez zmian). Wartości z `--dart-define`
zasilają pierwszy profil przy pierwszym uruchomieniu; potem obowiązuje
`settings.json`.

> Tokeny są zapisywane jawnym tekstem w `settings.json` w katalogu dokumentów
> aplikacji. Szyfrowanie zaplanowano na kolejną fazę.

### Queue — dodawanie pozycji

Nad przyciskiem nagrywania jest mniejszy przycisk notatki. Otwiera arkusz z
polem tekstowym; zapis tworzy plik `.txt`, weryfikuje go, indeksuje i dopiero
wtedy przetwarza (przepisanie treści, bez sieci). Przycisk notatki znika na
czas nagrywania, żeby akcja „SAVE” była jednoznaczna.

Karta pozycji zależy od typu: ikona, przycisk odtwarzania tylko dla audio,
czas trwania ukryty dla notatek i obrazów.

### Config — parametry nagrywania

Edytowalne: sample rate (8/16/22.05/44.1 kHz), bitrate (32–128 kbps), kanały
(mono/stereo). Kodek AAC-LC i kontener `.m4a` są stałe. Zmiana dotyczy wyłącznie
kolejnych nagrań — pliki już zapisane pozostają nietknięte.

## Pliki na dysku

Wszystko w podkatalogu `recordings/` katalogu dokumentów aplikacji, każdy zapis
atomowy (`.tmp` → `rename`):

- `<uuid>.<ext>` — materiał źródłowy pozycji (`.m4a` nagranie, `.txt` notatka),
- `recordings.json` — indeks wszystkich pozycji,
- `settings.json` — profile providerów i parametry audio,
- `logs.json` — historia zdarzeń (bufor cykliczny, maks. 500 wpisów).

## Kolejna faza

- pozostałe typy pozycji: wgrywanie plików audio, obrazy z OCR offline, wideo,
- kolejka background jobs,
- WorkManager na Androidzie i BGTaskScheduler na iOS,
- edycja tytułu i transkrypcji,
- lokalne modele na urządzeniu (whisper.cpp przez FFI),
- szyfrowanie tokenów,
- synchronizacja z Obsidian/Notion.

Projekt techniczny: `docs/superpowers/specs/2026-07-25-multimodal-capture-design.md`.

## Processing Console UI

The Phase 1 interface now uses the **Processing Console** design direction:

- dark navy interface with cyan system accent,
- processing filters: Queue, Ready, Failed, Raw,
- visible local-file verification status,
- processing metrics and transcription state,
- retry action for failed transcription,
- recording remains local-first: stop -> verify file -> persist metadata -> transcribe.

## Reviewed state and micro-animations

Each capture has a durable `isProcessedByUser` flag and optional `processedAt` timestamp. This state is independent from transcription status and persists in `recordings.json`.

The Processing Console includes:

- animated reviewed checkmark, card highlight and status pill,
- selection haptic feedback,
- animated reviewed counter and progress bar,
- full history retention: reviewed items stay visible,
- no "Inbox Zero" celebration or empty-inbox pressure.
