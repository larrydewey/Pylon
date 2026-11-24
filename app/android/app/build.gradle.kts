plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.pylon.pylon"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // The Resid core ships as executables named lib*.so (jniLibs/arm64-v8a,
    // copied there by tools/android-core.sh); they must be extracted to
    // nativeLibraryDir to be executable.
    buildFeatures {
        buildConfig = true
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    defaultConfig {
        applicationId = "dev.pylon.pylon"
        // Android 10: each terminal's emulator runs in an isolated process
        // of its own (Context.bindIsolatedService, SPEC 12). Older versions
        // can only put every terminal's emulator in one process, so they
        // are not supported rather than given the weaker sandbox.
        minSdk = 29
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        // Symbolon's signing certificates (SHA-256, comma-separated): the only
        // agent service Pylon binds (SPEC 7.3). The default is the certificate
        // Symbolon's published APKs carry; -PsymbolonCerts replaces it.
        val symbolonCerts = (project.findProperty("symbolonCerts") as String?)?.takeIf { it.isNotBlank() }
            ?: "7edf81fe80818c5593d8a3fb323a24791d090775403aea2cd88c507330c79826"
        buildConfigField("String", "SYMBOLON_CERTS", "\"" + symbolonCerts + "\"")
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Release builds are signed with the release key when the environment
    // names it (CI: ANDROID_KEYSTORE and friends, from repository secrets);
    // otherwise with the debug key, so `flutter run --release` works locally.
    // The release certificate is what the other app pins (Pylon <-> Symbolon,
    // SPEC 7.3), so a published APK must carry it.
    val releaseStore = System.getenv("ANDROID_KEYSTORE")?.takeIf { it.isNotEmpty() }
    signingConfigs {
        if (releaseStore != null) {
            create("release") {
                storeFile = file(releaseStore)
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("ANDROID_KEY_ALIAS")
                keyPassword = System.getenv("ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (releaseStore != null) "release" else "debug")
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

dependencies {
    // The QR decoder (Apache-2.0, no dependencies), with the platform camera:
    // QrScanner.kt. Its license and notice ship in assets/third_party/zxing.
    implementation("com.google.zxing:core:3.5.3")
}
