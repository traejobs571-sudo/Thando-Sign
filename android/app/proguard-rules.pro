# Flutter embedding
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.**  { *; }
-keep class io.flutter.embedding.engine.plugins.** { *; }

# Plugin registrant
-keep class io.flutter.plugins.GeneratedPluginRegistrant { *; }

# CameraX (camera plugin)
-keep class androidx.camera.** { *; }
-dontwarn androidx.camera.**

# TTS
-keep class com.tundralabs.fluttertts.** { *; }

# SQLite
-keep class com.tekartik.sqflite.** { *; }

# Connectivity
-keep class dev.fluttercommunity.plus.connectivity.** { *; }

# Permissions
-keep class com.baseflow.permissionhandler.** { *; }

# Play Core classes referenced by Flutter's deferred-component support (unused in a plain APK)
-dontwarn com.google.android.play.core.splitcompat.**
-dontwarn com.google.android.play.core.splitinstall.**
-dontwarn com.google.android.play.core.tasks.**
