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
    // 固定在 AGP 8.13.0：这是 media_kit_libs_android_audio 等插件自带 buildscript
    // 声明的版本。AGP 9 只暴露新 DSL 并移除了旧 Variant API，插件生态尚未迁移，
    // 使用 AGP 9 时这类插件模块编译拿不到 android.jar
    //（package android.content / android.net does not exist）。
    id("com.android.application") version "8.13.0" apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
}

include(":app")
