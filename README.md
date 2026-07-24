# Voice Notes — Phase 1

Minimalna aplikacja Flutter do nagrywania notatek głosowych w modelu **offline-first**.

## Gwarancja kolejności

Aplikacja zawsze wykonuje operacje w tej kolejności:

1. uruchamia nagrywanie do pliku `.m4a`,
2. zatrzymuje recorder,
3. sprawdza, czy plik istnieje i ma niezerowy rozmiar,
4. zapisuje metadane nagrania atomowo do `recordings.json`,
5. dopiero wtedy ustawia status `pendingTranscription`,
6. uruchamia transkrypcję,
7. błąd transkrypcji nie usuwa nagrania.

## Funkcje fazy 1

- nagrywanie AAC/M4A, mono, 16 kHz,
- lokalny zapis w katalogu dokumentów aplikacji,
- lista nagrań,
- trwałe statusy transkrypcji,
- ponawianie nieudanej transkrypcji,
- adapter HTTP gotowy pod Whisper/OpenAI/Hugging Face,
- brak funkcji usuwania nagrania w MVP, aby ograniczyć ryzyko utraty danych.

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
| **Queue** | lista nagrań, filtry statusu, wyszukiwarka, przycisk nagrywania, odtwarzanie |
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

### Config — parametry nagrywania

Edytowalne: sample rate (8/16/22.05/44.1 kHz), bitrate (32–128 kbps), kanały
(mono/stereo). Kodek AAC-LC i kontener `.m4a` są stałe. Zmiana dotyczy wyłącznie
kolejnych nagrań — pliki już zapisane pozostają nietknięte.

## Pliki na dysku

Wszystko w podkatalogu `recordings/` katalogu dokumentów aplikacji, każdy zapis
atomowy (`.tmp` → `rename`):

- `<uuid>.m4a` — audio,
- `recordings.json` — indeks nagrań,
- `settings.json` — profile providerów i parametry audio,
- `logs.json` — historia zdarzeń (bufor cykliczny, maks. 500 wpisów).

## Kolejna faza

- kolejka background jobs,
- WorkManager na Androidzie i BGTaskScheduler na iOS,
- edycja tytułu i transkrypcji,
- lokalne modele na urządzeniu (whisper.cpp przez FFI),
- szyfrowanie tokenów,
- synchronizacja z Obsidian/Notion.

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
