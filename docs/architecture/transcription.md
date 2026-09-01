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
  - **`WhisperModel.sha256` is nullable, and every shipped entry is currently null.** A pin can only be stated by downloading the file and computing it; inventing one would be worse than admitting there is none, because a wrong pin refuses every honest download. The store verifies when a pin is present and reports `InstalledModel.verified: false` when it is not, so "checked and correct" and "nothing to check against" stay different claims. `test/whisper_model_store_test.dart` asserts the entries are unpinned, with the failure message naming what to do when that changes.
  - **Installed state is read from disk on every call**, never remembered: a user with a file manager, or a phone reclaiming space, must stop being offered a model that is not there.
- **`AudioDecoder` (`transcription/data/audio_decoder.dart`) is a seam of its own, not a method on `AudioSplitter` where the plan first put it.** The two cannot share a failure philosophy: `UnavailableAudioSplitter.split` answers `AudioSegments.whole`, a *successful* degrade meaning "send it in one piece", and there is no equivalent for decoding — no PCM is not the whole file, it is nothing. One interface carrying both would force one implementation to degrade and to throw for the same kind of absence. The implementations are the same two classes either way (`FfmpegAudioDecoder` on desktop, `NativeMobileMediaProcessor` on Android/iOS), so it adds no dependency.
  - 16 kHz mono float32 is the model's format, not a preference. **`test/audio_decoder_test.dart` drives a real ffmpeg** — the second suite to do so, after the poster one, and for the same reason: a fake process runner proves the contract and nothing about whether the flags are right. It generates a 44.1 kHz **stereo** AAC tone on purpose, so a decode that ignored `-ar`/`-ac` produces a file three to six times the expected size; the assertion is the byte count, because headerless PCM's size *is* its sample count. The group skips when ffmpeg is absent.
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
- **whisper.cpp is fetched and pinned, not vendored.** `native/CMakeLists.txt` pulls `AUG_WHISPER_TAG` through `FetchContent`. The first configure needs the network; nothing at runtime ever does, which is the whole point of the feature. `EXCLUDE_FROM_ALL` keeps whisper's own `install()` rules out of ours — without it the bundle ships `libwhisper.a`, a 6 MB build input nothing can load.
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

## Long audio

**Long audio has three ceilings and only one of them tells you** — the 25 MB upload cap and the 1500 s duration limit answer 400, while the 2000-token output limit answers **HTTP 200 with a truncated transcript**. Every supported platform therefore splits before sending (`ChunkedTranscriptionService`); unknown platforms cap the recording instead. See `docs/architecture/transcription.md`.
