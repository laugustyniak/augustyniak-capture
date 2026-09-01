import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing is configured out-of-tree: `android/key.properties` names the
// keystore and carries its passwords, and neither file is tracked (.gitignore).
// The file is OPTIONAL by design — a clone without it still builds and runs in
// release mode, signed with the debug key, because this repo has no CI and a
// contributor who cannot run `--release` cannot check a build at all. Only a
// build meant for distribution needs the real key; see key.properties.example.
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
val keystoreProperties =
    Properties().apply {
        if (hasReleaseKeystore) {
            keystorePropertiesFile.inputStream().use { load(it) }
        }
    }

// A half-filled key.properties must fail the build loudly. Reading a missing
// entry straight into a signingConfig yields a bare NullPointerException from
// deep inside AGP, and the resulting artifact is either unsigned or signed with
// the wrong key — a failure that only surfaces at upload time.
fun keystoreProperty(name: String): String =
    keystoreProperties.getProperty(name)?.takeIf { it.isNotBlank() }
        ?: throw GradleException(
            "android/key.properties is present but has no `$name`. " +
                "Fill it in (see android/key.properties.example) or delete the " +
                "file to fall back to debug signing.",
        )

android {
    namespace = "ai.augustyniak.capture"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "ai.augustyniak.capture"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Required for `am instrument`; see MainActivityTest for why the
        // integration tests are run that way rather than through
        // `flutter test -d`.
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        externalNativeBuild {
            cmake {
                // Release flags even in a debug build of the app: this is a
                // speech model, and an -O0 ggml is slow enough on a phone to
                // read as a hang rather than as a debug build.
                cppFlags += listOf("-O3")
                arguments += listOf(
                    "-DCMAKE_BUILD_TYPE=Release",
                    "-DAUG_BUILD_WHISPER=ON",
                )
            }
        }

        // No `abiFilters` here on purpose. Flutter owns the ABI set — a debug
        // build is fat across all three, and `--target-platform` /
        // `--split-per-abi` are how a release narrows it — and an `abiFilters`
        // list in this block does not override that. It was tried: the APK
        // still carried `armeabi-v7a`, so the restriction would have been a
        // comment claiming something the build does not do.
        //
        // The consequence is that the shim is built for every ABI the app is,
        // which costs roughly 1.5 MB per slice. Narrowing it is a packaging
        // decision for the release build rather than something this file can
        // assert.
    }

    externalNativeBuild {
        cmake {
            path = file("../../native/CMakeLists.txt")
            // Newer than the NDK default of 3.22 where it is available; the
            // CMakeLists degrades to a 3.22-compatible fetch when it is not.
            version = "3.22.1"
        }
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperty("keyAlias")
                keyPassword = keystoreProperty("keyPassword")
                storePassword = keystoreProperty("storePassword")
                // Resolved against `android/`, so a relative path in
                // key.properties means the same thing wherever Gradle is
                // invoked from. An absolute path is used as-is, and is what
                // key.properties.example recommends: the keystore belongs
                // outside the checkout, where no `git clean` can reach it.
                storeFile =
                    keystoreProperty("storeFile").let { path ->
                        val candidate = File(path)
                        if (candidate.isAbsolute) candidate else rootProject.file(path)
                    }.also {
                        if (!it.exists()) {
                            throw GradleException(
                                "Keystore not found at ${it.absolutePath} " +
                                    "(storeFile in android/key.properties).",
                            )
                        }
                    }
            }
        }
    }

    buildTypes {
        release {
            signingConfig =
                signingConfigs.getByName(if (hasReleaseKeystore) "release" else "debug")
        }
    }
}

dependencies {
    // Instrumentation only — none of this reaches a release artifact.
    // Pinned to match: the integration_test plugin resolves
    // `androidx.test:runner` to strictly 1.3.0, and a newer rules artifact
    // drags a newer runner in with it and fails resolution.
    androidTestImplementation("androidx.test:runner:1.3.0")
    androidTestImplementation("androidx.test:rules:1.2.0")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
