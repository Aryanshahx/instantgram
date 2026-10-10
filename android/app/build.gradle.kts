plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    compileSdk = 36
    namespace = "com.hypertechlabs.instantgram"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    defaultConfig {
        applicationId = "com.hypertechlabs.instantgram"
        minSdkVersion = 21
        targetSdkVersion = 36
        versionCode = 1
        versionName = "1.0"
    }
}

flutter {
    source = "../.."
}
