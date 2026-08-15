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
            signingConfig = if (!releaseStore.isNullOrBlank()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
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
}
