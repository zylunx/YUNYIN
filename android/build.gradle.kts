plugins {
    // 只为在根脚本里引用 Kotlin 编译任务的类型（apply false：不实际应用）。
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

// media_kit_libs_android_audio 等插件在自己的 buildscript 里固定了旧版 AGP（8.13.0），
// 与主工程使用的 AGP 9.1.0 混用时，Gradle 9 下该模块的 android.jar 不会进入编译
// classpath（报 "package android.net does not exist"）。这里把子项目 buildscript 里的
// AGP 统一强制解析到主工程的版本。
subprojects {
    buildscript {
        configurations.all {
            resolutionStrategy.force("com.android.tools.build:gradle:9.1.0")
        }
    }
}

// 统一 JVM 目标：第三方插件（如 flutter_js）自带的 Java 目标与 Kotlin 默认值不一致时，
// Gradle 会报 "Inconsistent JVM-target compatibility" 并中断构建。
// 放在 projectsEvaluated 之后：此时各模块自己的脚本已执行完，不会被插件的旧值覆盖；
// 用 configureEach 惰性配置，也不会触发 "Cannot run afterEvaluate when project is already evaluated"。
gradle.projectsEvaluated {
    allprojects {
        tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
            compilerOptions {
                jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
            }
        }
        tasks.withType<org.gradle.api.tasks.compile.JavaCompile>().configureEach {
            sourceCompatibility = JavaVersion.VERSION_17.toString()
            targetCompatibility = JavaVersion.VERSION_17.toString()
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
