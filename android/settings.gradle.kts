pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.0.1" apply false
    // START: FlutterFire Configuration
    id("com.google.gms.google-services") version("4.4.4") apply false
    // END: FlutterFire Configuration
    id("org.jetbrains.kotlin.android") version "2.3.20" apply false
}

include(":app")

// v0.9.2: some Flutter plugins (ZEGO zego_zim) still use jcenter(), which
// Gradle 9 removed. Before Gradle reads them, jcenter() becomes mavenCentral().
run {
    val pluginList = file("../.flutter-plugins-dependencies")
    if (pluginList.exists()) {
        Regex("\"path\":\"([^\"]+)\"").findAll(pluginList.readText()).forEach { m ->
            val gradleFile = File(m.groupValues[1].replace("\\\\", "\\"), "android/build.gradle")
            if (gradleFile.exists()) {
                val text = gradleFile.readText()
                if (text.contains("jcenter()")) {
                    gradleFile.writeText(text.replace("jcenter()", "mavenCentral()"))
                    println("InstantGram: jcenter() fixed in ${gradleFile.parentFile.parentFile.name}")
                }
            }
        }
    }
}
