# Flutter custom proguard rules

# SQLCipher: Prevent R8 from stripping native encryption classes
# Required for release builds with minifyEnabled = true
-keep class net.sqlcipher.** { *; }
-keep class net.sqlcipher.database.* { *; }
