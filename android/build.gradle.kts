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
