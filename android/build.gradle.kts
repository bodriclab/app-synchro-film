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
// Certains plugins (mp_audio_stream) figent compileSdk 31 / NDK 21 : on les
// aligne sur l'app (les dépendances AndroidX récentes exigent compileSdk ≥ 34).
subprojects {
    afterEvaluate {
        extensions.findByType(com.android.build.gradle.LibraryExtension::class.java)?.apply {
            if ((compileSdk ?: 0) < 36) compileSdk = 36
            if (ndkVersion.startsWith("21.")) ndkVersion = "28.2.13676358"
            if ((defaultConfig.minSdk ?: 0) < 24) defaultConfig.minSdk = 24
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
