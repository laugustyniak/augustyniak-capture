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
    namespace = "com.audivoa.core"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.audivoa.core"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
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

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
