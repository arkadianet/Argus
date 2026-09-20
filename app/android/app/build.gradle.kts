plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.argus.argus_wallet"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications uses java.time; desugar for older APIs.
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.argus.argus_wallet"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
    }

    splits {
        abi {
            isEnable = true
            reset()
            include("arm64-v8a", "x86_64")
            isUniversalApk = true
        }
    }

    // libwallet_ffi.so is built for arm64-v8a and x86_64 only. Dependencies
    // (ML Kit, CameraX, DataStore) ship armeabi-v7a natives, and the
    // universal APK picked them up in alpha.57's build, which would let a
    // 32-bit device install an app that dies loading the wallet library.
    packaging {
        jniLibs {
            excludes += listOf("lib/armeabi-v7a/**", "lib/x86/**")
        }
    }

    val releaseStore = System.getenv("ARGUS_KEYSTORE")
    signingConfigs {
        create("release") {
            if (!releaseStore.isNullOrBlank()) {
                val storePassword = System.getenv("ARGUS_KEYSTORE_PASSWORD")
                val keyAlias = System.getenv("ARGUS_KEY_ALIAS")
                val keyPassword = System.getenv("ARGUS_KEY_PASSWORD")
                    ?: storePassword
                require(!storePassword.isNullOrBlank()) { "ARGUS_KEYSTORE_PASSWORD is required" }
                require(!keyAlias.isNullOrBlank()) { "ARGUS_KEY_ALIAS is required" }
                require(!keyPassword.isNullOrBlank()) { "ARGUS_KEY_PASSWORD is required" }
                storeFile = file(releaseStore)
                this.storePassword = storePassword
                this.keyAlias = keyAlias
                this.keyPassword = keyPassword
            }
        }
    }

    buildTypes {
        release {
            require(!releaseStore.isNullOrBlank()) {
                "Release builds require ARGUS_KEYSTORE. Copy example.env to .env and set the signing values."
            }
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("androidx.security:security-crypto:1.1.0-alpha06")
    implementation("androidx.biometric:biometric:1.1.0")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
