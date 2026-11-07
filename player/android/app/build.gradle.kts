import java.util.Properties
import com.chaquo.python.ChaquopyExtension

plugins {
    id("com.android.application")
    id("com.chaquo.python") apply false
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val radioWheels = System.getenv("RADIO_ANDROID_WHEELS")
val hasLocalEngine = !radioWheels.isNullOrBlank()
if (hasLocalEngine) {
    apply(plugin = "com.chaquo.python")
    configure<ChaquopyExtension> {
        defaultConfig {
            version = "3.13"
            buildPython("py", "-3.13")
            pip {
                options("--find-links", file(radioWheels!!).absolutePath)
                // Match the runtime pins used by the standalone Windows engine.
                val pinned = Regex("^([a-z0-9-]+==[^\\s]+)", RegexOption.MULTILINE)
                for (entry in pinned.findAll(rootProject.file("../../requirements.lock").readText())) {
                    install(entry.groupValues[1])
                }
            }
        }
        sourceSets.getByName("main").srcDir(rootProject.file("../../"))
        sourceSets.getByName("main").include("radio_prototype/**")
    }
}

val radioSigning = Properties().apply {
    val source = rootProject.file("../../data/android-signing.properties")
    if (source.exists()) source.inputStream().use { load(it) }
}

android {
    namespace = "dev.personalradio.personal_radio"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "29.0.13113456"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets.getByName("main").java.srcDir(
        if (hasLocalEngine) "src/embedded/kotlin" else "src/serverOnly/kotlin"
    )

    defaultConfig {
        if (hasLocalEngine) ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.personalradio.personal_radio"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("personalRelease") {
            if (radioSigning.isNotEmpty()) {
                storeFile = file(radioSigning.getProperty("storeFile"))
                storePassword = radioSigning.getProperty("storePassword")
                keyAlias = radioSigning.getProperty("keyAlias")
                keyPassword = radioSigning.getProperty("keyPassword")
            }
        }
    }
    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("personalRelease")
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
