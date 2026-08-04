import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.calvin.expense_tracker"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String?
            keyPassword = keystoreProperties["keyPassword"] as String?
            storeFile = keystoreProperties["storeFile"]?.let { file(it) }
            storePassword = keystoreProperties["storePassword"] as String?
        }
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.calvin.expense_tracker"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = 35
        multiDexEnabled = true
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

val verifyReleaseOffline by tasks.registering {
    group = "verification"
    description = "Fails release builds that gain Internet access or remote SDKs."
    dependsOn("processReleaseMainManifest")

    doLast {
        val mergedManifest = layout.buildDirectory.file(
            "intermediates/merged_manifest/release/processReleaseMainManifest/AndroidManifest.xml"
        ).get().asFile
        check(mergedManifest.isFile) {
            "Release merged manifest was not generated: ${mergedManifest.absolutePath}"
        }
        val manifestText = mergedManifest.readText()
        check(!manifestText.contains("android.permission.INTERNET")) {
            "Offline guarantee violated: release manifest requests android.permission.INTERNET"
        }

        val forbiddenRemoteComponents = listOf(
            "firebase-analytics",
            "firebase-crashlytics",
            "play-services-analytics",
            "sentry-android",
            "bugsnag-android",
            "appcenter-analytics",
            "appcenter-crashes",
            "newrelic-android-agent",
            "datadog-android",
            "amplitude-analytics",
            "mixpanel-android",
            "segment-analytics",
            "appsflyer",
            "adjust-android",
            "okhttp",
            "retrofit"
        )
        val resolvedComponents = configurations.getByName("releaseRuntimeClasspath")
            .incoming.resolutionResult.allComponents
            .map { it.id.displayName.lowercase() }
        val forbiddenMatches = resolvedComponents.filter { component ->
            forbiddenRemoteComponents.any(component::contains)
        }
        check(forbiddenMatches.isEmpty()) {
            "Offline guarantee violated by release dependencies: " +
                forbiddenMatches.sorted().joinToString()
        }
    }
}

tasks.matching { it.name == "assembleRelease" }.configureEach {
    dependsOn(verifyReleaseOffline)
}
