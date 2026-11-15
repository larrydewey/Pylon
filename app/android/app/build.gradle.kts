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
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        // Symbolon's release certificates (SHA-256, comma-separated): the only
        // agent service Pylon binds (SPEC 7.3). Empty: no agent on Android.
        buildConfigField("String", "SYMBOLON_CERTS", "\"" + (project.findProperty("symbolonCerts") ?: "") + "\"")
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // The core exists for this one (tools/android-core.sh).
        ndk { abiFilters += listOf("arm64-v8a") }
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
