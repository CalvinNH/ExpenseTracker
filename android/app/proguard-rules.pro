# Flutter custom proguard rules

# SQLCipher: Prevent R8 from stripping native encryption classes
# Required for release builds with minifyEnabled = true
-keep class net.sqlcipher.** { *; }
-keep class net.sqlcipher.database.* { *; }

# Room creates generated database implementations via reflection. Its bundled
# consumer rule keeps the class name, but current R8 can still remove the
# zero-argument constructor required by WorkManager's WorkDatabase_Impl.
-keep class * extends androidx.room.RoomDatabase {
    public <init>();
}
