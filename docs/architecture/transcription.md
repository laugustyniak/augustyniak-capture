# On-device transcription and the long-audio ceilings

The local-engine seam and model store, and the three limits a single provider request runs into — one of which answers HTTP 200 with a truncated transcript.

**On-device transcription** (`features/transcription/domain/local_transcription_engine.dart`, `data/local_transcription_service.dart`) — slice 0 of `docs/plans/2026-08-16-on-device-transcription.md` (#4). The seam only: there is no inference and no model file yet, and `UnavailableLocalEngine` is the default everywhere.

- **A third `TranscriptionService` implementation, and no new architecture** — it is reached from the drain loop minutes after a capture is verified and on disk, so the capture ordering #4 asked not to disturb is preserved by construction rather than by care.
- **`ProfileKind.localWhisper` rather than a separate setting.** The Models tab already manages named things with an active selection per kind, and a local model is asked the same questions. A local-engine setting beside the profile list would make two sources of truth about which transcriber is active — the bug that follows is a user who switched one and is still being charged by the other.
- **`toService` reads the kind *before* the endpoint, and that reordering is the change a local profile forced.** The blank-endpoint guard is deliberate for a half-filled remote profile; a local one has no endpoint by definition, so leaving the guard first would make every on-device model silently disabled by a rule written for a different mistake. It also means a local profile with an endpoint typed in by hand still never sends audio anywhere. `SettingsController._buildTranscriptionService` builds the local service instead, because it owns the engine and the model store while the profile only names which model it wants — and `kind` is in the cache signature, or switching a profile from remote to local would keep the cached `http.Client`.
- **An older build reads `localWhisper` as `transcription`** (`fromName` falls back rather than dropping), then posts to a blank endpoint and degrades to disabled: inert, not destructive. Written down before it is discovered.
- **`WhisperModelStore` (`transcription/data/`) keeps model files in Application Support, never in documents.** `recoverOrphans()` re-adopts anything in the recordings directory that is not an index or a poster, so a half-gigabyte model beside the sources becomes a capture on the next launch. It carries the same `directoryProvider` seam as `RecordingsRepository`, so the whole download-verify-rename pipeline is tested against a temp directory with no platform binding.
  - **Streamed to `<name>.part`, then renamed** — the atomic discipline every index here uses, with a stronger reason: a torn model is not unreadable, it is merely *worse*, and nothing downstream would ever say so. **Every exit from the transfer discards the partial**, cancellation included; with the cleanup sitting after the `try` it never ran for a throw raised inside the loop, and a surviving `.part` is the one artifact this class must not produce.
  - **Truncation is caught by comparing what arrived against the server's own `Content-Length`**, not against a catalog number. That check needs no shipped data and cannot go stale.
  - **Every shipped `WhisperModel` pins a `sha256` (#303).** The values are the Hugging Face LFS `oid sha256:` lines for `ggml-<id>.bin`; `tiny-q5_1` was checked against a real download when they were added, the other three are copied from the pointers. A mismatch is refused and the `.part` deleted like every other failed exit. `InstalledModel.verified` is true only when this store hashed the bytes itself: a successful download leaves a `<file>.sha256` marker holding the hash, `installed()` reads the marker rather than rehashing half a gigabyte per scan, and a marker naming anything but the current pin counts as absent. An install from before the pins, or a file dropped in by hand, has no marker and shows "not verified" until it is deleted and fetched again. `test/whisper_model_store_test.dart` refuses a catalog entry without a 64-hex pin and checks that `.github/workflows/ci.yml` carries as many checksum lines with that value as it has `tiny-q5_1` fetches. The field stays nullable for the store's contract only: a model handed in without a pin installs as unverified, so "checked and correct" and "nothing to check against" stay different claims.
  - **Installed state is read from disk on every call**, never remembered: a user with a file manager, or a phone reclaiming space, must stop being offered a model that is not there.
- **`AudioDecoder` (`transcription/data/audio_decoder.dart`) is a seam of its own, not a method on `AudioSplitter` where the plan first put it.** The two cannot share a failure philosophy: `UnavailableAudioSplitter.split` answers `AudioSegments.whole`, a *successful* degrade meaning "send it in one piece", and there is no equivalent for decoding — no PCM is not the whole file, it is nothing. One interface carrying both would force one implementation to degrade and to throw for the same kind of absence. The implementations are the same two classes either way (`FfmpegAudioDecoder` on desktop, `NativeMobileMediaProcessor` on Android/iOS), so it adds no dependency.
  - 16 kHz mono float32 is the model's format, not a preference. **`test/audio_decoder_test.dart` drives a real ffmpeg** — the second suite to do so, after the poster one, and for the same reason: a fake process runner proves the contract and nothing about whether the flags are right. It generates a 44.1 kHz **stereo** AAC tone on purpose, so a decode that ignored `-ar`/`-ac` produces a file three to six times the expected size; the assertion is the byte count, because headerless PCM's size *is* its sample count. The group skips when ffmpeg is absent.
  - **A container with no `moov` atom is repaired into the temp directory, never in place.** An interrupted stop leaves every sample in `mdat` and no index; ffmpeg answers `moov atom not found`, and `FfmpegAudioDecoder` and `FfmpegAudioSplitter` then give `AudioRepairer` one attempt. `FfmpegAudioRepairer` copies the broken file into `<tempDir>/repair/`, runs `untrunc` on the *copy* (against a sibling capture's header, or a synthetic one ffmpeg generates), and hands back the `_fixed` output from that directory — so the source is only ever read, the recordings directory never sees a transient artifact `findOrphans` would adopt by name, and `DecodedAudio.dispose()` / `AudioSegments.dispose()` clear the repair with everything else. The run then repeats on the copy with repair disabled. A splitter that yields one part from a *repaired* input returns it as `AudioSegments.parts`, not `whole`, because `ChunkedTranscriptionService` sends the caller's own file whenever `!isSplit` — and that file is the one ffmpeg just refused. The cost is that the file on disk stays unplayable and each retry repairs again; adopting the repaired copy into the recording is a controller decision (#177), not a processor's. `test/audio_repair_test.dart` drives real ffmpeg + untrunc on a tone with its `moov` cut off and pins the source's bytes.
  - **Exit code zero is not a decode.** ffmpeg can succeed having written nothing — the trap the poster extractor already documents — and the native channel can return cleanly having written nothing too. Both paths check the output exists and is non-empty, because an empty buffer reaches a model as silence and comes back as confident nonsense rather than as a failure.
- **`LocalModelsSection` is the Models tab's third section**, and it is shown even where the engine is missing — hiding it would make "this build cannot run a model" indistinguishable from "this build has no such feature". The banner says which, **once**, rather than once per capture. Downloading and deleting stay available without an engine; only `USE` is inert, because a control that can only fail is worse than one that is not there.
  - **Selecting a model creates one `localWhisper` profile and reuses it** (`SettingsController.useLocalModel`). The profile is an implementation detail of "which model is active", and a list that grows every time somebody switches back and forth is a list nobody can read.
  - **"Nothing is installed" is a positive claim about the user's disk**, so the section renders `Checking…` until the first scan answers and reports a failed scan rather than showing an empty catalog. Same rule as `_indexUnreadable` and the timer's `historyUnreadable`.
  - `ModelsTab` takes an injectable `modelStore` for the reason every IO seam here is injectable: the widget suite must not reach `path_provider`. **Adding the section broke a neighbouring test in a way worth remembering** — `models_tab_test` asserted a section count after a hand-tuned `drag` offset, and a `ListView` builds its children lazily, so an off-screen header is not merely invisible, it is absent from the element tree. `ensureVisible` replaced the magic number.
- **Two failures, deliberately not one.** `LocalTranscriptionUnavailableException` is "this build cannot run a model at all"; `LocalModelMissingException` is "download the one you chose". Collapsing them would send a user looking for a different build when a download would do. The model path is resolved **per call**, like the vault's directory, so a model deleted between two captures is found out rather than handed to the engine as a stale path.

**Long audio has three ceilings, and only one of them tells you.** A single `/audio/transcriptions` request is bounded by the 25 MB upload cap (a 400), by the `gpt-4o` family's 1500 s duration limit (also a 400) — and by that family's **2000-token output limit, which answers HTTP 200 with a truncated `text`**. The third is why any of this exists: a twenty-minute capture came back as roughly nine minutes of transcript, was written `completed`, went to the clipboard, and had its title enriched from the part that survived. Nothing downstream could tell, and `RecordingStatus` has no value for "succeeded partially". The two answers to it are split by platform:

- **Every supported app platform splits before sending.** `ChunkedTranscriptionService` (`transcription/data/`) is a decorator on `TranscriptionService`, so microphone captures, uploads and video audio all share one path. Android uses MediaExtractor/MediaMuxer, iOS uses AVFoundation, and desktop uses `FfmpegAudioSplitter`. Parts are transcribed sequentially and joined in order; a file that yields one part is handed to the inner service unwrapped.
- **Unknown platforms cap the recording instead.** Where `AudioSplitter.isAvailable` is false, `TranscriptionLimits.forRequest` computes the binding ceiling from the active profile's model and bitrate. The shell sets `controller.recordingLimit` only there; null everywhere else means no cap.
  - Enforced in `RecordingsController._onTick`, not in `RecordingView`: it is an invariant of the capture, so it has to hold for a hotkey-started recording and must not depend on a widget being mounted. Reaching it calls the **same `stopRecording` the SAVE button calls** — the capture is saved, never discarded. `RecordingView` draws the countdown and the reason, so the automatic save is something the user watched approach.
  - `stopRecording`'s teardown lives in `finally` for the same reason. It used to sit after the `stop()` await inside the `try`, so a recorder that threw there left `_isRecording` true with the 250 ms timer alive: the capture screen never closed, and once a cap existed the tick called straight back into `stopRecording` four times a second for the rest of the session.


## On-device

**On-device transcription** (`features/transcription/`) — a third `TranscriptionService` implementation behind `ProfileKind.localWhisper`, reached from the drain loop like any other. `WhisperModelStore` keeps model files in Application Support, never in documents, or `recoverOrphans()` adopts them as captures.

**The inference ships on Linux and Android.** `WhisperFfiEngine` decides its own availability once, at construction, and every other platform gets a reason instead — the Models tab says so once rather than the app failing once per capture. That asymmetry is the point of `LocalTranscriptionEngine.isAvailable` being synchronous.

### The native build

- **A thin C shim, not direct bindings.** `native/augustyniak_whisper.{h,c}` exposes exactly three functions. `whisper_full_params` is a large struct whose layout changes between whisper.cpp releases, and replicating it in `dart:ffi` would not fail to compile on a version bump — it would read the wrong fields. Everything version-sensitive is resolved in C, against the headers the library was actually built with.
- **whisper.cpp is fetched and pinned, not vendored.** `native/CMakeLists.txt` pulls `AUG_WHISPER_REF` — a commit hash, not the tag it names — through `FetchContent`. The first configure needs the network; nothing at runtime ever does, which is the whole point of the feature. `EXCLUDE_FROM_ALL` keeps whisper's own `install()` rules out of ours — without it the bundle ships `libwhisper.a`, a 6 MB build input nothing can load.
- **`GGML_NATIVE` is off.** ggml defaults to `-march=native`, which bakes in whatever the build machine supports and then dies with SIGILL on an older CPU — at the first transcription, not at startup. A shipped artifact has to run on the machines it is copied to.
- **`CMAKE_POSITION_INDEPENDENT_CODE` is on** for the whole dependency tree, or the static archives link into the shared library with a relocation error against `stderr` that names the symbol rather than the cause.
- The shim silences whisper's log callback. `print_*` governs transcript output; the loader talking to stderr is separate, and inside an app that is the user's terminal.

### Android

The NDK build runs the same `native/CMakeLists.txt` through `externalNativeBuild` in `android/app/build.gradle.kts`, and Gradle packages the `.so` under `lib/<abi>/` in the APK — the one platform where `DynamicLibrary.open` by bare name is right, because the APK's library path is the app's own rather than a shared system one.

Two things had to exist before the engine could work there at all:

- **`decodeAudioToPcm` on the Kotlin side.** Slice 3 wrote the Dart half of the mobile decoder, but `MainActivity` implemented `extractVideoAudio`, `extractVideoPoster` and `splitAudio` only — the channel method fell through to `notImplemented()`. A MediaExtractor/MediaCodec decode now produces headerless 16 kHz mono float32. The resample is nearest-sample, deliberately: whisper's own front end is a mel spectrogram over a 16 kHz signal, and the artefacts a windowed resampler would remove sit above what that representation keeps.
- **`EXCLUDE_FROM_ALL` had to become version-guarded.** The NDK ships CMake 3.22 and that keyword arrived in 3.28, where an unknown keyword is a hard configure error. Android runs no `install()` step, so it takes the fallback and loses nothing.

`abiFilters` is deliberately absent: Flutter owns the ABI set, an `abiFilters` list in `defaultConfig.ndk` does not override it (tried — the APK still carried `armeabi-v7a`), and narrowing it belongs to the release packaging rather than to that file.

### Where it runs

The FFI call is blocking and CPU-bound — a minute of audio is seconds of solid compute — so `WhisperFfiEngine` runs it through `Isolate.run`. On the main isolate the UI stops painting mid-capture, including the queue reporting the capture it is working on. The isolate re-opens the library because a `DynamicLibrary` cannot cross an isolate boundary; that costs a `dlopen` of something already mapped. Thread count is half the cores, so the machine stays usable.

The library is located relative to the running executable, never by bare name: a bare `dlopen` searches the system loader path, and finding a stranger with the same file name is worse than finding nothing.

### Verifying it

`test/whisper_engine_native_test.dart` exercises the real engine and **skips unless the artifacts exist**, so a machine with no native build stays green rather than failing for a feature it never built:

```bash
flutter build linux --release
AUG_WHISPER_LIB=build/linux/x64/release/bundle/lib/libaugustyniak_whisper.so \
AUG_WHISPER_MODEL=/path/to/ggml-tiny-q5_1.bin \
AUG_WHISPER_AUDIO=/path/to/a-capture.m4a \
  flutter test test/whisper_engine_native_test.dart
```

On Android it is `integration_test/whisper_android_test.dart`, run through `am instrument` against an **already-installed** app. `flutter test -d <device>` cannot be used: it reinstalls on every run and the install clears the data directory, so a model staged beforehand is gone before the first line executes. The artifacts are piped in through `run-as` because neither end of a direct push works — a directory `adb` creates under `/sdcard/Android/data` belongs to `shell` with mode 770 and the app's uid cannot traverse it, while the app's uid cannot read `/data/local/tmp`.

```bash
export JAVA_HOME=/path/to/android-studio/jbr   # the JDK Flutter reports; a JRE has no javac
cd android && ./gradlew app:assembleDebug app:assembleDebugAndroidTest \
  -Ptarget=integration_test/whisper_android_test.dart && cd ..
adb install -r build/app/outputs/apk/debug/app-debug.apk
adb install -r build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk

adb push ggml-tiny-q5_1.bin /data/local/tmp/model.bin
adb push a-capture.m4a      /data/local/tmp/capture.m4a
adb shell run-as ai.augustyniak.capture mkdir -p files
adb shell 'cat /data/local/tmp/model.bin  | run-as ai.augustyniak.capture sh -c "cat > files/model.bin"'
adb shell 'cat /data/local/tmp/capture.m4a | run-as ai.augustyniak.capture sh -c "cat > files/capture.m4a"'

adb shell cmd connectivity airplane-mode enable    # the half of the acceptance that matters
adb shell am instrument -w ai.augustyniak.capture.test/androidx.test.runner.AndroidJUnitRunner
```

## Remote

**Transcription** (`features/transcription/data/transcription_service.dart`): `TranscriptionService` interface with two remote impls. `DisabledTranscriptionService` throws `TranscriptionNotConfiguredException`; it is the fallback whenever no provider profile is active. `HttpWhisperTranscriptionService` POSTs `multipart/form-data` field `file` to a configurable endpoint, optional bearer token, expects `{"text": ...}` (falls back to `transcript`).

## Live dictation

Streaming speech-to-text **beside** recording (#481), selected by an active `ProfileKind.liveTranscription` profile (`AppSettings.activeLiveProfileId`, the Models tab's third section). It does not replace persistence or the batch pipeline: the WAV is written to disk chunk by chunk regardless, and any failure of the live path means the take is transcribed after stop like any other. The capture-side order is in `docs/architecture/capture-pipeline.md#live-dictation-capture`; the endpoint guard is in `docs/architecture/settings-security.md`.

**The seam** (`transcription/domain/live_transcription.dart`). `LiveTranscriptionService` (`isAvailable`, `sampleRate`, `start()`) and `LiveTranscriptionSession` (`updates`, `addAudio`, `finish`, `cancel`). `DisabledLiveTranscriptionService` is the default: `isAvailable` false, `start()` throws, so an unconfigured install records m4a exactly as before. `LiveTranscript` is `committed` (text the provider will not revise), `partial` (the current guess, replaced by every update) and `failed` plus an optional `reason` (the session died; the screen says live is off and the take is transcribed after stop; the reason is a close code, an HTTP status or the provider's own error text, **never a URI, header or token**, because the controller logs it). `SettingsController.liveTranscriptionService` is a resolver cached by signature, like `transcriptionService`; the controller takes a `Function()`, so a Models change only affects takes started afterwards.

**The adapters** (`transcription/data/live/`). `LiveWsService` owns the connection (`dart:io` `WebSocket.connect`, no new dependency), and a provider subclass states only its wire protocol (`buildUri`, `headers`, `openMessages`, `encodeAudio`, `handle`, `finishMessages`, `isDrained`, `isTerminal`, optional keepalive). `start()` returns at once and connects in the background; audio is buffered (30 s, oldest dropped) until the socket opens. `addAudio` never throws. A socket error, close or provider error emits `failed: true` (with a `reason`) with the committed text kept and the unfinalised partial dropped (a guess from a dead stream is not text the provider committed to). **Provider by host** (`live_provider_factory.dart`, `liveProviderForHost`): `deepgram.com`, `soniox.com`, `elevenlabs.io`, `openai.com` (and subdomains); an unknown host gives the disabled service rather than a guessed protocol. A connect that times out closes the socket if the handshake completes late (`WebSocket.connect(...).timeout` does not cancel it). The factory's `provider:` override exists so tests can point an adapter at a loopback `ws://` server.

**`finish()` contract.** It sends the provider's end frames and waits for the provider's final or terminal signal, bounded by `finishTimeout` (default 8 s). It **returns the full committed text, partial included, only on a clean finish**. It **throws `LiveTranscriptionIncomplete`** (its `reason` says why) when the session died before finishing (drop, error, refused connection), when it was cancelled, when the provider reported a hole (`LiveSessionState.incomplete`: OpenAI `…transcription.failed`), or when no final signal arrived before the timeout. **A socket close is a terminal signal only for Deepgram (`closeIsTerminal`) and only with code 1000**; for the others a close during finish is a cut stream, and a 1006/1011 close never counts as complete anywhere. The controller turns that into `null` and runs the batch processor on the WAV: a text that may be missing its tail is never trusted. The controller bounds its own wait for the future at 20 s (`liveResultTimeout`) on top of the session's 8 s.

**Keepalive per provider** (sent only when no audio went out in the interval, and not once `finishing`):

| Provider | Keepalive |
| --- | --- |
| Deepgram | `{"type":"KeepAlive"}` every 5 s (server closes after about 10 s of silence) |
| Soniox | `{"type":"keepalive"}` every 15 s (documented maximum gap 40 s) |
| ElevenLabs | none |
| OpenAI | none |

**Pause.** `toggleRecordingPause` calls `recorder.pause()`, which stops the chunks; the session sees a gap with no audio. Deepgram and Soniox ride it out on the keepalive. **ElevenLabs and OpenAI have no keepalive here and may drop the socket on a long pause**; that turns into `failed` (the log line carries the close code, so the cause is visible), and the take falls back to batch at stop. Whether `pause()` actually silences the stream on the pinned `record_linux` fork has not been exercised in stream mode.

**Per provider** (endpoint, auth, framing, end of stream):

| Provider | Endpoint, auth | Audio | Ends with |
| --- | --- | --- | --- |
| Deepgram Nova-3 | `wss://api.deepgram.com/v1/listen?model=…&encoding=linear16&sample_rate=16000&interim_results=true…`, `Authorization: Token <key>` | binary PCM16 frames | `Finalize`, `CloseStream`; terminal is `Metadata` or a close |
| Soniox | `wss://stt-rt.soniox.com/transcribe-websocket`, `Authorization: Bearer` and `api_key` in the first config frame | binary frames; tokens concatenated verbatim, `<end>`/`<fin>` dropped | `{"type":"finalize"}`, then an **empty text frame**; terminal is `finished: true` |
| ElevenLabs Scribe realtime | `wss://api.elevenlabs.io/v1/speech-to-text/realtime?model_id=…&audio_format=pcm_16000&commit_strategy=manual`, `xi-api-key` | JSON text frames, `input_audio_chunk` with base64; the adapter commits every 15 s (`commit: true` on the chunk) | an empty chunk with `commit: true` (only if at least 100 ms is uncommitted); terminal is the `committed_transcript` that answers the last commit **sent**: commits are counted, so an earlier answer arriving late does not end the wait (with `commit_strategy=vad` a server-made commit is indistinguishable from the answer to ours) |
| OpenAI `gpt-live-transcribe` | `wss://api.openai.com/v1/realtime?intent=transcription`, `Authorization: Bearer`, **24 kHz** | JSON `input_audio_buffer.append` with base64; no server VAD, so the adapter commits every 15 s | a commit (only if at least 100 ms is uncommitted: the server rejects less, and that error would discard complete text); terminal is the last pending `…transcription.completed`/`failed`. Committed text is released **in buffer order** (`input_audio_buffer.committed` `item_id`/`previous_item_id`), not arrival order; a `failed` item is a hole and `finish()` throws |

**Verified only against the vendors' docs of 2026-11-28 and against loopback test servers (`test/live_transcription_test.dart`) — never against the live services in CI.** Each unverified detail below is written in the adapter's doc comment too; `test/live_stt_smoke_test.dart` is the opt-in check that closes them.

| Provider | Unverified |
| --- | --- |
| Deepgram | the `KeepAlive` frame; behaviour of `Metadata` as the terminal reply after `CloseStream` |
| Soniox | `audio_format: pcm_s16le`; whether `api_key` in the config is still required beside the Bearer header; the `keepalive` and error frame shapes (`error_code`/`error_message`); `finished: true` |
| ElevenLabs | `commit_strategy=manual` with `commit: true` on audio chunks; the end-of-stream request (empty chunk with `commit: true`) and the minimum audio a commit accepts (the 100 ms floor is a guess); that a `committed_transcript` follows each commit; error `message_type` names |
| OpenAI | the `input_audio_buffer.committed` event carrying `previous_item_id`; the `session.update` nesting (`session.audio.input.format/transcription/turn_detection`); Polish support (the preset says so); the 24 kHz rate and the commit-every-15 s workaround |

An unverified end-of-stream request costs at most the `finishTimeout`, then a `LiveTranscriptionIncomplete` and the batch fallback: the failure mode of a wrong guess is a slower transcript, never a lost one.

**No usage or cost events for live takes in v1.** A live take is not billed through `UsageSink`: the provider's per-minute price is not in the `PriceBook`, and when the live text is used the batch processor never runs, so the editor's COST panel shows nothing for the take. A batch fallback is costed as usual.

**The opt-in smoke test.** `test/live_stt_smoke_test.dart` builds each real adapter through `buildLiveTranscriptionService` with the preset's endpoint and model and streams a speech WAV (`LIVE_STT_SAMPLE_WAV`). A provider runs only when `LIVE_STT_<DEEPGRAM|SONIOX|ELEVENLABS|OPENAI>_KEY` is set; otherwise it is skipped, so plain `flutter test` never touches the network. The OpenAI case needs a 24 kHz sample.

## Long audio

**Long audio has three ceilings and only one of them tells you** — the 25 MB upload cap and the 1500 s duration limit answer 400, while the 2000-token output limit answers **HTTP 200 with a truncated transcript**. Every supported platform therefore splits before sending (`ChunkedTranscriptionService`); unknown platforms cap the recording instead. See `docs/architecture/transcription.md`.
