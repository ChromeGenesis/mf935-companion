plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Stable release signing: the keystore is committed (see gradle.properties)
// so every build — local or CI — produces upgrade-compatible APKs. When
// it is absent (fresh fork clone), fall back to the debug key so the
// build still succeeds.
val releaseKeystore = rootProject.findProperty("mf935KeystoreStoreFile")
    ?.let { rootProject.file(it) }
val hasReleaseKeystore = releaseKeystore?.exists() == true

android {
    namespace = "com.genesis.mificompanion"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.genesis.mificompanion"
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
                storeFile = releaseKeystore
                storePassword = rootProject.findProperty("mf935KeystoreStorePassword")?.toString()
                keyAlias = rootProject.findProperty("mf935KeystoreKeyAlias")?.toString()
                keyPassword = rootProject.findProperty("mf935KeystoreKeyPassword")?.toString()
            }
        }
    }

    buildTypes {
        // Personal sideload project: sign debug with the same committed
        // keystore so `flutter run` installs OVER the release build
        // (same cert -> update, data preserved) instead of failing with
        // INSTALL_FAILED_UPDATE_INCOMPATIBLE.
        debug {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                // No committed keystore available: debug-sign so
                // `flutter build apk --release` still works.
                signingConfigs.getByName("debug")
            }
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
