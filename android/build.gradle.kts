plugins {
    id("com.android.application") version "9.0.1" apply false
    id("org.jetbrains.kotlin.android") version "1.9.22" apply false
}

tasks.withType<JavaCompile>().configureEach {
    javaCompiler.set(
        javaToolchains.compilerFor {
            languageVersion.set(JavaLanguageVersion.of(17))
        }
    )
}
