plugins {
    // 只为在根脚本里引用 Kotlin / AGP 的类型（apply false：不应用到根项目本身）。
    id("org.jetbrains.kotlin.android") apply false
    id("com.android.library") version "9.1.0" apply false
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// 第三方插件（如 flutter_js）自带的 Java / Kotlin 目标版本可能与本项目不一致，
// 统一成 17，否则 Gradle 会报 "Inconsistent JVM-target compatibility"。
// 用 configureEach 惰性配置，避免 evaluationDependsOn(":app") 引起的求值顺序问题。
subprojects {
    tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }
    // 兜底：个别插件在 DSL 之外直接设置过 JavaCompile，这里再统一一次。
    tasks.withType<org.gradle.api.tasks.compile.JavaCompile>().configureEach {
        sourceCompatibility = JavaVersion.VERSION_17.toString()
        targetCompatibility = JavaVersion.VERSION_17.toString()
    }
}

allprojects {
    pluginManager.withPlugin("com.android.library") {
        extensions.configure<com.android.build.gradle.LibraryExtension> {
            compileOptions {
                sourceCompatibility = JavaVersion.VERSION_17
                targetCompatibility = JavaVersion.VERSION_17
            }
        }
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

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
