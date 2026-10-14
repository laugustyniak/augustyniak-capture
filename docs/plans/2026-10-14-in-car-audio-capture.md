# In-car audio capture (issue #267)

Stage 2 of in-car capture. Stage 1 (#266, merged in #270) lets Siri and the Google Assistant drop a *text* note into the inbox. Stage 2 records the *car microphone* itself: an Android Auto screen with REC and STOP, and a CarPlay request that cannot be built until Apple approves it.

## Summary

- A native Kotlin car app (`android/app/src/main/kotlin/ai/augustyniak/capture/car/`) built on the Car App Library 1.7.0. It contains no Flutter code and never starts the Flutter engine.
- `CarRecorder` reads PCM from `CarAudioRecord`, encodes AAC-LC at 16 kHz, mono, 64 kbps with `MediaCodec`, and muxes it into MPEG-4 with `MediaMuxer`. It writes `<filesDir>/inbox/<uuid>.m4a.tmp`.
- `CarCaptureFiles.finalize` syncs the file, renames it to `<uuid>.m4a` and verifies the length is above zero. The screen shows "Saved" only when it returns `Saved`. This is the same persist-before-confirm rule as `CreateNoteActivity`.
- `InboxDrainer` accepts `*.m4a` when it is given an `ingestAudio` callback. `RecordingsController.addAudioFile(id, file)` copies the file into the app directory through `MediaImporter`, persists the row as `saved`, and only then enqueues processing. The inbox file is deleted after `addAudioFile` returns true. The inbox uuid becomes the Recording id, so ingestion is idempotent.
- The Android Auto side needs `androidx.car.app:app` and `androidx.car.app:app-projected`. `CarAudioRecord.create` loads its implementation by name and throws without the projected artifact.

## Decisions

- **Category IOT.** The Car App Library has no notes or dictation category. IOT is the closest declared category for a personal capture tool. Whether an internal test track accepts it is unconfirmed until the first upload.
- **A stale `*.m4a.tmp` is kept, not swept.** The one-hour sweep stays limited to `*.txt.tmp`: a text producer renames within milliseconds, so an old `.txt.tmp` is a dead write with nothing in it. An old `.m4a.tmp` is an interrupted recording that may be the only copy of what the user said. The drainer logs one warning per drain with the count of `*.m4a.tmp` files older than one hour, so they can be recovered by hand. A file younger than that may still be recording and is not reported. Recovering them automatically would need an ADTS container (a stream that stays playable when truncated) instead of MPEG-4, whose index is written at the end; that is a possible follow-up.
- **Fixed format.** 16 kHz, mono, 64 kbps AAC-LC, the app's own defaults for mic capture. `CarAudioRecord` delivers 16 kHz 16-bit mono PCM, so there is nothing to choose. The Config tab's audio settings do not apply to the car.
- **`durationMs` is 0.** The inbox carries a file, not a measurement, and `MediaImporter` records `0` for imported audio. The transcription step does not depend on it.
- **No foreground service.** The microphone arrives from the Android Auto host over a pipe (`ProjectedCarAudioRecord` reads an `InputStream`). Neither the library sources nor its manifest reference a foreground service or `AudioRecord`, so the Android 14 microphone foreground-service rule for phone-microphone capture does not apply. The host keeps the `CarAppService` bound for the session.
- **Host validation.** A debug build accepts any host (needed for the Desktop Head Unit). A release build accepts only the hosts in the library's `hosts_allowlist_sample`.
- **Car API level 5.** `CarAudioRecord` needs it. Below it the screen only asks the user to update Android Auto.

## Known limitations

- The capture reaches the queue, and therefore sync, only when the app is next opened or resumed. Nothing drains the inbox while the app is not running.
- The app is hidden by Android Auto unless it was installed from Google Play. See `docs/platform-setup.md`, "Android Auto".
- A crash or a killed process during a recording leaves `<uuid>.m4a.tmp` behind. It is logged but not ingested.
- The MessageTemplate title and header action use the pre-API-7 builder methods, which are deprecated but are the ones that work at API level 5.
- The Desktop Head Unit was not available when this was built. The recording path was verified by unit tests of the file handling and by a debug and a release build, not on a head unit.
- CarPlay is not implemented. See the request below; its four spoken commands are part of the scope once Apple approves it.

## CarPlay entitlement request

Submit at https://developer.apple.com/contact/carplay/ for `com.apple.developer.carplay-voice-based-conversation`. Without approval a provisioning profile cannot include the entitlement, even for personal use, so no CarPlay code is written until it is granted.

Apple describes the category as apps that, after launch, "appropriately respond to questions or requests and perform actions". A recorder that only listens fits that weakly, so the request describes a small set of spoken commands. **They are a commitment, not a pitch**: the CarPlay implementation must ship every command listed below, and nothing the request promises may be left out of it.

- "save" ends the note and stores it; the app answers "Saved" only once the audio is on disk.
- "cancel" ends the note and keeps nothing; the app answers "Cancelled".
- "read back my last note" speaks the transcript of the most recent capture, or "Not transcribed yet" when there is none.
- "how many notes today" speaks the count of today's captures.

Ready to paste:

> **App:** Augustyniak Capture
> **Bundle identifier:** ai.augustyniak.capture
> **Entitlement:** com.apple.developer.carplay-voice-based-conversation
>
> **What the app does.** Augustyniak Capture is a personal voice recorder. The user speaks a note, the app stores the audio on the device, and later turns it into text.
>
> **CarPlay flow.** The experience is voice-first. The user launches the app from CarPlay and it starts listening immediately. There is no wake word and no menu to navigate. The user speaks a note, and the app responds to spoken requests:
>
> - "save": the app stores the note and answers "Saved" once the audio is on the device.
> - "cancel": the app discards the note and answers "Cancelled".
> - "read back my last note": the app speaks the text of the most recent note.
> - "how many notes today": the app speaks the number of notes captured today.
>
> **What is shown while driving.** Nothing beyond the system CarPlay voice interface. All responses are spoken. The app shows no text and no imagery while the car is moving.
>
> **What is captured and where it goes.** The audio is written to the device first, and a confirmation is spoken only after the file is stored. The app then sends it to the transcription provider the user configured themselves, and to the user's own private sync storage. No audio goes to any service the user did not choose, and nothing is used for advertising or analytics.
>
> **Who it is for.** It is a personal productivity tool: a driver captures and reviews their own notes by voice, without touching the screen.
