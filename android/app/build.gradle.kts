import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keyPropertiesFile = rootProject.file("key.properties")
val releaseKeyProperties = Properties().apply {
    if (keyPropertiesFile.isFile) {
        keyPropertiesFile.inputStream().use { load(it) }
    }
}
val hasReleaseSigning = releaseKeyProperties.getProperty("storeFile")?.isNotBlank() == true &&
    releaseKeyProperties.getProperty("storePassword")?.isNotBlank() == true &&
    releaseKeyProperties.getProperty("keyAlias")?.isNotBlank() == true &&
    releaseKeyProperties.getProperty("keyPassword")?.isNotBlank() == true
val useDevSuffix = providers.gradleProperty("quelyt.devSuffix").orNull == "true"
val requestedTargetPlatforms = (providers.gradleProperty("target-platform").orNull ?: "")
    .split(',')
    .map { it.trim() }
    .filter { it.isNotEmpty() }

android {
    namespace = "dev.localstudy.local_study"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "dev.localstudy.local_study"
        minSdk = maxOf(flutter.minSdkVersion, 24)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = rootProject.file(releaseKeyProperties.getProperty("storeFile"))
                storePassword = releaseKeyProperties.getProperty("storePassword")
                keyAlias = releaseKeyProperties.getProperty("keyAlias")
                keyPassword = releaseKeyProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        debug {
            if (useDevSuffix) {
                applicationIdSuffix = ".dev"
            }
        }
        release {
            // Use production keystore from android/key.properties when provided;
            // CI / local development builds fall back to debug signing.
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }

    // Strip unmatched native ABIs from Maven dependencies (e.g. tesseract4android)
    // when building a single-ABI APK such as android-arm64 or android-x64.
    packaging {
        jniLibs {
            val allAbis = listOf("armeabi-v7a", "arm64-v8a", "x86", "x86_64")
            val mapped = requestedTargetPlatforms.mapNotNull {
                when (it) {
                    "android-arm" -> "armeabi-v7a"
                    "android-arm64" -> "arm64-v8a"
                    "android-x86" -> "x86"
                    "android-x64" -> "x86_64"
                    else -> null
                }
            }.toSet()
            if (mapped.isNotEmpty()) {
                for (abi in allAbis) {
                    if (abi !in mapped) {
                        excludes.add("lib/$abi/**")
                    }
                }
            }
        }
    }

    sourceSets.getByName("main").java.srcDir("../../native_ocr/android")
}

dependencies {
    implementation("cz.adaptech.tesseract4android:tesseract4android:4.9.0")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
