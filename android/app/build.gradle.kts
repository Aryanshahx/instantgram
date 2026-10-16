import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    // END: FlutterFire Configuration
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// v0.20: release signing key (the same key for the APK and the .aab).
//  * GitHub Actions: from the secrets (see .github/workflows/build-apk.yml)
//  * your computer: android/key.properties (never pushed to GitHub)
//  * no key: signed with the debug key (only for testing)
val keyProps = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) FileInputStream(f).use { load(it) }
}

fun signValue(env: String, prop: String): String? =
    System.getenv(env)?.takeIf { it.isNotBlank() }
        ?: keyProps.getProperty(prop)?.takeIf { it.isNotBlank() }

val releaseStoreFile = signValue("ANDROID_KEYSTORE_PATH", "storeFile")
val releaseStorePassword = signValue("ANDROID_KEYSTORE_PASSWORD", "storePassword")
val releaseKeyAlias = signValue("ANDROID_KEY_ALIAS", "keyAlias")
val releaseKeyPassword = signValue("ANDROID_KEY_PASSWORD", "keyPassword")
val hasReleaseKey = releaseStorePassword != null &&
    releaseKeyAlias != null &&
    releaseKeyPassword != null &&
    releaseStoreFile?.let { file(it).exists() } == true

if (!hasReleaseKey) {
    logger.warn("InstantGram: no release key found, the release build uses the debug key")
}

android {
    namespace = "com.hypertechlabs.instantgram"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.hypertechlabs.instantgram"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = maxOf(flutter.minSdkVersion, 24)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (hasReleaseKey) {
                storeFile = file(releaseStoreFile!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKey) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
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
