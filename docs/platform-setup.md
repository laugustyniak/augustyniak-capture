# Platform build and CI

Every pin and failure mode below was found by building on a clean machine; none is discoverable from the code. Read this before the first build of a platform, before touching `android/`, `ios/`, `macos/`, the signing configuration or `.github/workflows/ci.yml`.

**The mobile toolchain has two pins that are not optional.** Both were found by
building on a clean machine; neither is discoverable from the code.

- **AGP must stay on 8.x** (`android/settings.gradle.kts`), even though
  `flutter create` generates 9.0.1. Under AGP 9 the plugin set deadlocks:
  `file_picker` 11 deliberately skips applying KGP (it expects AGP 9's
  `android.builtInKotlin`, which the Flutter template sets to `false`), while
  `audioplayers_android` 5.3.0 applies `kotlin-android` unconditionally, which
  AGP 9 rejects outright. No value of the flag satisfies both. The first half
  fails **silently**: Gradle reports `BUILD SUCCESSFUL` and emits an AAR whose
  `classes.jar` is 22 bytes, and the failure only surfaces later as
  `cannot find symbol: class FilePickerPlugin` from `GeneratedPluginRegistrant`.
  Revisit when `audioplayers_android` ships an AGP 9 build — it is the only
  blocker, and 5.3.0 is currently its newest release.
- **Gradle must run on JDK 21, not on Android Studio's bundled JBR.** Current
  Android Studio ships Java 25, and the older KGP versions the plugins pull in
  (`audioplayers` declares Kotlin 1.7.10) cannot parse a two-digit Java version —
  the build dies on `IllegalArgumentException: 25.0.2` inside the Kotlin
  compiler, with no mention of Java in the message. Install Temurin 21 and point
  Flutter at it once per machine:

```bash
brew install --cask temurin@21
flutter config --jdk-dir "/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home"
```

**`ios/Runner/Info.plist` is hand-maintained and must stay complete.** It is not
regenerated, so a missing key is invisible until deploy time: without
`CFBundleIdentifier` the app still builds and `flutter build ios` reports
success, but the product has no bundle identity and `simctl install` refuses it
with _"Missing bundle ID"_. It also carries `NSMicrophoneUsageDescription` (the
mic is the whole app) and the `UIApplicationSceneManifest` that wires up
`SceneDelegate.swift` — drop the latter and Flutter warns about the UIScene
migration on every build.

**Recording in the background is a platform declaration on both phones, and
neither failure says anything.** This is not an optimisation: without them a
locked screen ends a capture mid-sentence, with no exception, no status change
and an elapsed timer still counting against a file that stopped growing. It
shipped that way, and no test in this repo can see it — both halves live
entirely outside Dart.

- **Android**: microphone access has been _while-in-use_ since 9, so the system
  takes the input away the moment the activity stops being visible. The manifest
  therefore declares `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MICROPHONE`,
  `POST_NOTIFICATIONS`, and `CaptureForegroundService` with
  `foregroundServiceType="microphone"`. **Android 14 checks the type in the
  manifest _and_ the one passed to `startForeground()`** — both are required.
  The notification is the price of the exemption, not decoration: the system
  will not grant one without it. Denying `POST_NOTIFICATIONS` suppresses the
  notification but not the service, so the capture still survives.
- **iOS**: `UIBackgroundModes: audio` in `Info.plist`, and that is the whole of
  it — `record_ios` already sets a `.playAndRecord` session and activates it, so
  the only thing missing was permission to keep running off-screen.
- Verify Android by grepping the **merged** manifest after a build
  (`build/app/intermediates/merged_manifests/.../AndroidManifest.xml`) rather
  than the source one; a service the merge dropped looks identical from here.
  Neither platform can be verified without a device: record, lock the screen,
  wait, unlock. `recoverOrphans()` softens a killed capture by re-adopting the
  partial `.m4a`, but an AAC file whose container was never finalised is not
  reliably playable — what comes back is a row, not the words.

**Android release signing is opt-in and lives out of the tree.** `android/app/build.gradle.kts` reads `android/key.properties` (untracked; template in `android/key.properties.example`) and, **only if that file exists**, signs release builds with the named keystore. Absent it, release falls back to the debug key exactly as the Flutter template did — deliberate, because there is no CI here and a contributor without the keystore must still be able to run `flutter build apk --release` to check a build. The corollary is the trap: **a release artifact is debug-signed unless you verify otherwise**, and nothing in the build output says so. Check before uploading anything:

```bash
apksigner verify --print-certs build/app/outputs/flutter-apk/app-release.apk
# `CN=Android Debug` means the fallback ran — key.properties was missing.
```

A `key.properties` that exists but is incomplete, or that points at a keystore that is not there, fails the build with a written explanation rather than a null-pointer from inside AGP. The keystore is the one artifact in this project that cannot be regenerated: once a build is on Play under `ai.augustyniak.capture`, losing the key means no future build can ever update it.

**The macOS App Sandbox is off, and that is the platform's load-bearing decision.** Both `macos/Runner/Release.entitlements` and `DebugProfile.entitlements` set `com.apple.security.app-sandbox` to `false` — they must stay in agreement, or a debug run cannot reproduce an installed-app bug. The reason is that a sandboxed process hands its sandbox to every child it spawns, which breaks both of this app's desktop shell-outs at once: `ffmpeg` could not read the recordings directory, and `open` could not reach LaunchServices. They break _the same clean way a missing binary does_ — the item lands `failed` with its source intact — so the sandbox is invisible as a cause. Turning it back on is a Mac App Store prerequisite, not a security fix: it needs `device.audio-input`, `network.client` and `files.user-selected.read-only` **and** in-process replacements (Vision, AVFoundation, NSWorkspace) before those three features work again. `NSMicrophoneUsageDescription` is in `macos/Runner/Info.plist` and is not optional — without it macOS kills the process at `recorder.hasPermission()`, i.e. on the first recording rather than at launch.

**One entitlement is required anyway, sandbox or no sandbox**: `com.apple.security.files.user-selected.read-only`, in **both** entitlements files. `file_picker` 11 does not rely on the sandbox to enforce it — `FilePickerPlugin.checkEntitlement` calls `SecTaskCopyValueForEntitlement` on its own task and refuses up front, so without the key **every** picker call answers `PlatformException(ENTITLEMENT_NOT_FOUND)`: `pickFiles`, i.e. all three upload capture types, and `getDirectoryPath`, i.e. the project editor's repository-path browse button. It cost the upload path on macOS silently, because nothing in the Dart layer or the test suite can see a check that lives in the signature. Verify it on the built bundle rather than in the file — `codesign -d --entitlements - "build/macos/Build/Products/Debug/Augustyniak Capture.app"` is the same question the plugin asks.

**Signing is opt-in per machine, and defaults to ad-hoc.** `CODE_SIGN_IDENTITY` reads `$(LOCAL_SIGN_IDENTITY)`, which `Debug.xcconfig` and `Release.xcconfig` set to `-` and then override from an **untracked** `macos/Runner/Configs/LocalSigning.xcconfig` via `#include?` — the `?` is what keeps a clone without the file building exactly as before. Same shape and same reasoning as `android/key.properties`. `CODE_SIGN_STYLE` must stay `Manual`: with `Automatic` and a non-empty identity Xcode refuses the build outright with _"requires a development team"_, and a self-signed certificate has no team. `test/macos_signing_test.dart` pins all of it, because `flutter create --platforms=macos .` rewrites these files back to the template.

**Being untracked is exactly why a new worktree signs ad-hoc, and this repo is normally worked from worktrees.** `git worktree add` materialises what is *in the repository*, so `LocalSigning.xcconfig` — deliberately not in it — does not come along, `LOCAL_SIGN_IDENTITY` falls back to `-`, and that worktree's builds are hash-bound strangers again. This is not hypothetical: it is the fourteenth-build story below, reproduced from scratch in a worktree whose only purpose was two unrelated one-line fixes. The launch prompted for the login keychain password, which is precisely the state that once emptied every provider token. Copy the file into each new worktree before the first build, and check the requirement rather than the config, because only the built bundle can answer:

```bash
cp macos/Runner/Configs/LocalSigning.xcconfig <worktree>/macos/Runner/Configs/
codesign -d -r- "build/macos/Build/Products/Release/Augustyniak Capture.app"
# `cdhash H"…"` means the copy was missed; the certificate-leaf form is the one the keychain grant covers.
```

**Why bother, given there is no Apple account:** an ad-hoc signature has no identity beyond the hash of the binary, so the designated requirement _is_ `cdhash H"…"` and **every rebuild is a different application to macOS**. The login keychain's ACL names the hashes it trusts and TCC keys the microphone grant the same way, so each build re-prompts and an unapproved one is refused — which is how the token master key became unreadable and every request went out with no `Authorization` header (see `docs/architecture/settings-security.md`). Any certificate, self-signed included, moves the requirement to `identifier "ai.augustyniak.capture" and certificate leaf = H"…"`, which survives rebuilds and is shared by every worktree building the same bundle id. Verified rather than assumed: two builds of this bundle, different `cdhash`, identical `codesign -d -r-`. A self-signed root costs nothing — Keychain Access → Certificate Assistant → Create a Certificate, _Self Signed Root_ + _Code Signing_ — but it is **not** a Team ID, so it does not unlock the data protection keychain and does not make the app distributable.

Two consequences remain: macOS keys microphone consent to the code signature, so **switching** the signing identity re-prompts for the mic once (an ad-hoc build re-prompted on every rebuild); and a Release build still carries `get-task-allow`, so it is debuggable. `PRODUCT_BUNDLE_IDENTIFIER` is pinned to `ai.augustyniak.capture` in `macos/Runner/Configs/AppInfo.xcconfig` — `flutter create` derives something like `ai.augustyniak.augustyniakCapture` from the org, which is a _different_ app to every store and update mechanism. Without the sandbox, `getApplicationDocumentsDirectory()` resolves to `~/Documents`, so captures live in `~/Documents/recordings/` rather than in a container. Install a standalone copy with:

```bash
flutter build macos --release
cp -R "build/macos/Build/Products/Release/Augustyniak Capture.app" /Applications/
```

`SystemHotkeyRegistrar` is now genuinely reachable on macOS (it was dead code while there was no `macos/` target), but its `rejected` set still relies on `hotKeyManager.register` throwing on refusal, which the plugin does not document — check the Config tab rather than trusting an empty rejection list.

**Regenerating one platform rewrites `.metadata`.** `flutter create --platforms=macos .` left _only_ `root` and `macos` under `migration.platforms`, silently dropping android/ios/linux/windows. Restore the other entries by hand; `flutter migrate` reads that list.

**Linux builds need `keybinder-3.0` installed first.** `hotkey_manager` (global
shortcuts) links against it, and without it `flutter build linux` aborts at
_"Unable to generate build files"_ — this is a **build-time** failure, not a
runtime degradation, so nothing runs at all:

```bash
sudo apt-get install keybinder-3.0   # resolves to libkeybinder-3.0-dev
```

**Linux builds also need `libsecret-1-dev`** — `flutter_secure_storage` links
against libsecret for the token-encryption master key. Without it
`flutter build linux` fails at build time. At runtime a keyring daemon
(gnome-keyring) must be running and unlocked, otherwise token encryption
degrades to plaintext with a visible Config-tab warning:

```bash
sudo apt-get install libsecret-1-dev
```

**CI runs on GitHub Actions** (`.github/workflows/ci.yml`), on every push to
`main` and on every pull request. Two jobs: *Analyze + test* on Ubuntu
(`flutter analyze`, `flutter test`, then a debug APK) and *Build macOS + iOS*
plus a Windows build on their own runners. It was parked for a long time
because Actions minutes were metered, which is true of a private repository —
this one is public (`gh repo view` reports `PUBLIC`; the note about captured
content leaking into commits, in `CLAUDE.md`, depends on that), and standard-runner
minutes are free for public repositories, so cost is not a reason to turn it
off again.

**A green Actions badge is not a green build.** The Apple job spent a day
failing on `pod install` alone — `mobile_scanner` needs iOS 15.5 and the
project declared 13.0 — while analyze, test, Windows and macOS all passed, so
the run summary had to be opened to see it. Checks that a runner can make in
six minutes and a Dart test can make in one second belong in the Dart test:
`ios_deployment_target_test.dart` and `macos_signing_test.dart` both exist for
that reason.

**The iOS job builds for a device rather than the simulator.** It is the artefact that ships, so it is the one worth gating — but the reason it started that way is worth keeping: `mobile_scanner` 6.x pulled in GoogleMLKit, which **ships no arm64 slice for the simulator**, and `macos-latest` is Apple Silicon with an iOS 26+ simulator where arm64 is required. The plugin was dropped from the link and the build died on `Module 'mobile_scanner' not found`, a message naming neither MLKit nor the architecture. Locally the same state was only a warning and the simulator build succeeded, which is why it read as a runner quirk for a day. `mobile_scanner` 7.x replaced MLKit with native APIs — fourteen CocoaPods dependencies became two, the iOS floor dropped from 15.5 back to the template's 13.0, and the simulator builds cleanly — so this is now a preference rather than a constraint.

Global shortcuts on **Linux** additionally need `sudo apt-get install keybinder-3.0` (`hotkey_manager`'s system dependency). Without it the registrar fails at runtime and the shortcuts degrade to unavailable — everything else still works.

Raising the window from a hotkey on **GNOME/X11** additionally wants `xdotool`
(`sudo apt-get install xdotool`). It is optional: without it a hotkey still
captures, but the window only blinks in the taskbar instead of coming forward —
see `SystemWindowPresenter`.
