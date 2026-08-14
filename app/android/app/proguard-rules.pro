# Keep Google error-prone annotations used by Tink (security-crypto dependency)
-keep class com.google.errorprone.annotations.** { *; }
-keep class javax.annotation.** { *; }
-dontwarn com.google.errorprone.annotations.**
-dontwarn javax.annotation.**

# Keep flutter_rust_bridge generated classes
-keep class com.argus.argus_wallet.** { *; }