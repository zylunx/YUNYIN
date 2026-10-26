plugins {
    // apply false：只把 KGP 放上根 buildscript 的 classpath，让仍在用旧式
    // `apply plugin: 'kotlin-android'` 的插件模块能解析到；根脚本自身不应用它。
    id("org.jetbrains.kotlin.android") apply false
}

allprojects {
    repositories {
        google()
        mavenCentral()
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
}
subprojects {
    project.evaluationDependsOn(":app")
}

// 说明：media_kit_libs_android_audio 等插件在自己的 buildscript 里固定了 AGP 8.13.0
// 并用旧式 `apply plugin: 'com.android.library'`。为避免两份 AGP 混用，主工程也固定在
// 8.13.0（见 settings.gradle.kts），此时插件自带的版本与主工程一致，无需再强制解析。

// 不要在这里统一覆写 JavaCompile 的 sourceCompatibility / targetCompatibility。
// AGP 把 android.jar 通过 JavaCompile.options.bootstrapClasspath 交给 javac，而 Gradle
// 在 target >= 9 时会静默丢弃 -bootclasspath。在 projectsEvaluated 里改 target（AGP 已
// 决定好 bootstrapClasspath 之后），会导致所有带 Java 源码的插件模块（media_kit_libs_
// android_audio、flutter_displaymode…）编译时看不到 android.jar，报
// "package android.content / android.util / android.view does not exist"。
// 只有 Kotlin 源码的 :app 不受影响（javac 任务是 NO-SOURCE），所以问题容易漏判。
//
// Kotlin 与 Java 目标不一致（如 flutter_js 自带 Java 11、Kotlin 默认 1.8）改用
// gradle.properties 里的 kotlin.jvm.target.validation.mode=warning 降级处理。

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
