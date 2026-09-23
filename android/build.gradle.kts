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
// Pin one NDK for every Android plugin module (avoids AGP auto-selecting a
// different default NDK than the one installed on build machines).
subprojects {
    if (!state.executed) {
        afterEvaluate {
            extensions.findByName("android")?.withGroovyBuilder {
                "setNdkVersion"("27.0.12077973")
            }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
