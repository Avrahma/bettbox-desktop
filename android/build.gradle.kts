
allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
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
// 构建环境修复：AGP 9.3.1 的 lint 在部分插件上崩溃（CommentDetector removeLast），
// 该定制包不需要 lint 检查，直接禁用所有 lint 任务。
subprojects {
    tasks.configureEach {
        if (name.startsWith("lintVital") || name.startsWith("lintAnalyze")) {
            enabled = false
        }
    }
}
