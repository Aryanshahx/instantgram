plugins {
    id("com.android.application") apply false
    id("org.jetbrains.kotlin.android") apply false
}

tasks.withType<JavaCompile>().configureEach {
    javaCompiler.set(
        javaToolchains.compilerFor {
            languageVersion.set(JavaLanguageVersion.of(17))
        }
    )
}
