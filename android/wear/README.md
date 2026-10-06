# Capture for Wear OS

This is a separate, standalone watch APK (`ai.augustyniak.capture.wear`). It
records with the watch microphone and keeps completed `.m4a` files in the
watch's app-private `files/recordings/` directory. The phone and a network are
not required. Server upload is a later slice; uninstalling this app currently
deletes its local recordings.

## Screens

The UI follows the *Capture Wear OS* design (claude.ai/design, project
"Capture"), built in Wear Compose Material 3 on pure black:

- **Home** — the tile's layout in the app: one large accent button records,
  below it the count on the watch and its state. The state reads `local`
  (amber) because nothing leaves the watch yet; the design's `sync` dot
  arrives with upload.
- **Recording** — big timer, a waveform from the microphone level, a red ring
  on the edge that fills once a minute, stop under the thumb. Haptic tick at
  start and stop.
- **Saved** — a check, the duration and "on this watch" for 2 s, then back
  home. No upload progress, for the same reason.
- **Queue** — tap the count on Home. A scaling list (rows narrow and dim at
  the edge, crown scrolls): dot, title, duration and day. A red dot marks a
  `.pending` file the recorder never finished; it is listed, never deleted.
- **Detail** — label, title, date and size, and playback.
- **Empty queue** — the count and the record button straight away.
- **Tile** — the Home layout; one tap starts, a second stops.
- **Complications** — *Record* (small/monochromatic image, short text) toggles
  recording; *Capture queue* (short text) shows the count and opens the queue.
  Both open the activity rather than starting the microphone themselves,
  because Android does not allow a microphone service from the background.

Not built, because each needs the phone link or the server: the analysis
result notification, the Done / Enrich / To agent / Add more actions, and the
design's sync state. Long-press of the hardware button is a system setting,
not something the app can claim.

Wear Compose 1.7 needs compileSdk 37 and AGP 9.1; the project pins AGP 8.x, so
the module stays on the 1.6 line. Font licences ship in `assets/licenses/`.

## Build

Build from the repository root after Flutter has generated `android/gradlew`
and `android/local.properties` (a normal `flutter build apk --debug` does both):

```bash
cd android
JAVA_HOME=/opt/android-studio/jbr ./gradlew :wear:testDebugUnitTest :wear:assembleDebug :wear:lintDebug
```

The APK is `build/wear/outputs/apk/debug/wear-debug.apk` relative to the
repository root. To install it on a connected watch, use that watch's serial
from `adb devices -l`:

```bash
adb -s WATCH_SERIAL install -r build/wear/outputs/apk/debug/wear-debug.apk
```

On the watch, grant microphone permission, record for several seconds, let the
screen sleep, reopen Capture, and tap the stop button. The count on Home should
increase. To try the tile on an emulator without the picker:

```bash
adb shell am broadcast -a com.google.android.wearable.app.DEBUG_SURFACE \
  --es operation add-tile --ecn component ai.augustyniak.capture.wear/.CaptureTileService
adb shell am broadcast -a com.google.android.wearable.app.DEBUG_SYSUI \
  --es operation show-tile --ei index 0
``` Device validation also needs a playback check: pull the resulting
`.m4a` from app-private storage with `run-as` on a debug build and play it.
