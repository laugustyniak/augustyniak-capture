# Capture for Wear OS

This is a separate, standalone watch APK (`ai.augustyniak.capture.wear`). It
records with the watch microphone and keeps completed `.m4a` files in the
watch's app-private `files/recordings/` directory. The phone and a network are
not required. Server upload is a later slice; uninstalling this app currently
deletes its local recordings.

Build from the repository root after Flutter has generated `android/gradlew`
and `android/local.properties` (a normal `flutter build apk --debug` does both):

```bash
cd android
JAVA_HOME=/opt/android-studio/jbr ./gradlew :wear:assembleDebug :wear:lintDebug
```

The APK is `build/wear/outputs/apk/debug/wear-debug.apk` relative to the
repository root. To install it on a connected watch, use that watch's serial
from `adb devices -l`:

```bash
adb -s WATCH_SERIAL install -r build/wear/outputs/apk/debug/wear-debug.apk
```

On the watch, grant microphone permission, record for several seconds, let the
screen sleep, reopen Capture, and tap **Stop and save**. The saved count should
increase. Device validation also needs a playback check: pull the resulting
`.m4a` from app-private storage with `run-as` on a debug build and play it.
