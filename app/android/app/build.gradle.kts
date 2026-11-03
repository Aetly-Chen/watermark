import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 正式签名。口令放在 app/android/key.properties（已被 .gitignore 排除），
// keystore 本身放在仓库外（D:/dev/android-keys/）—— 一次 .gitignore 失误不应该变成密钥泄露。
// 没有这个文件时退回 debug 签名，保证 `flutter run` 和 CI 不至于直接构建失败。
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        FileInputStream(keystorePropertiesFile).use { load(it) }
    }
}
val hasReleaseKey = keystorePropertiesFile.exists()

android {
    namespace = "cn.shuiyin.watermark_remover"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "cn.shuiyin.watermark_remover"
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

    // 只把 arm64-v8a 的原生库打进包。
    //
    // OpenCV 的 Maven 包（org.opencv:opencv:4.14.0）会把每个 ABI 的
    // libopencv_java4.so 都塞进 APK：x86_64 57.7MB + arm64 23.5MB + armeabi-v7a 15.3MB。
    // 而 `--target-platform android-arm64` 只约束 Flutter 自己的 libflutter/libapp，
    // 管不到依赖带来的 jniLibs —— 结果一个给真机用的包 124MB，其中 57.7MB 是模拟器架构的
    // OpenCV（实测 2026-10-31）。
    //
    // 注意：`defaultConfig.ndk.abiFilters` 在这里**不生效**（实测过，依赖 AAR 里的 jni
    // 照样被打进去），必须用 packaging 层面的 excludes。加完 arm64 单包 49MB（原 124MB）。
    // 要出 32 位包，去掉 armeabi-v7a 那行，并在 build_release.sh 里同时传
    // `--target-platform android-arm64 android-arm`。
    packaging {
        jniLibs {
            excludes += listOf("lib/x86_64/**", "lib/armeabi-v7a/**")
        }
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // 有 key.properties 就用正式密钥，否则退回 debug（并打印警告，别让它悄悄发生）。
            signingConfig = if (hasReleaseKey) {
                signingConfigs.getByName("release")
            } else {
                logger.warn("⚠️ 没有 app/android/key.properties，release 将用 debug 密钥签名")
                signingConfigs.getByName("debug")
            }
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // OpenCV 官方 Maven 包（4.9 起发布，含各 ABI 的 .so，无需手动拷 jniLibs）
    // 用 4.x 而不是 5.0：Imgproc.inpaint 的 API 在 4.x 上稳定，5.x 是新的主版本
    implementation("org.opencv:opencv:4.14.0")
}

flutter {
    source = "../.."
}
