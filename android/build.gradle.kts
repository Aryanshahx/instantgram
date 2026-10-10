// InstantGram: the call plugin (agora) reads this to compile against a modern Android API.
if (!extra.has("compileSdkVersion")) {
    extra["compileSdkVersion"] = 36
ntasks.withType<JavaCompile> {
    javaCompiler.set(javaToolchains.compilerFor {
        languageVersion.set(JavaLanguageVersion.of(17))
    })
}
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
ntasks.withType<JavaCompile> {
    javaCompiler.set(javaToolchains.compilerFor {
        languageVersion.set(JavaLanguageVersion.of(17))
    })
}
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
ntasks.withType<JavaCompile> {
    javaCompiler.set(javaToolchains.compilerFor {
        languageVersion.set(JavaLanguageVersion.of(17))
    })
}
}
subprojects {
    project.evaluationDependsOn(":app")
ntasks.withType<JavaCompile> {
    javaCompiler.set(javaToolchains.compilerFor {
        languageVersion.set(JavaLanguageVersion.of(17))
    })
}
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
ntasks.withType<JavaCompile> {
    javaCompiler.set(javaToolchains.compilerFor {
        languageVersion.set(JavaLanguageVersion.of(17))
    })
}
}
