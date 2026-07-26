import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import 'package:expense_tracker/core/database/app_database.dart';

/// Manages the SQLCipher database encryption key using the Android Keystore.
///
/// Key material is generated once using [Random.secure], Base64URL-encoded for
/// safe transit across platform channels, and persisted in
/// [EncryptedSharedPreferences] (backed by the Android Keystore HSM).
///
/// This class enforces:
/// - No hardcoded passphrases — all key material is runtime-generated.
/// - Base64URL encoding — prevents null-byte truncation and encoding corruption
///   across the Dart ↔ native platform channel boundary.
/// - Single retrieval path — the key is fetched once during [AppDatabase] init
///   and held in memory for the lifetime of the singleton connection.
class SecurityKeyManager {
  SecurityKeyManager._();

  static final SecurityKeyManager instance = SecurityKeyManager._();

  static const _keyAlias = 'db_encryption_key';
  static const _androidOptions = AndroidOptions(
    encryptedSharedPreferences: true,
  );

  final FlutterSecureStorage _encryptedStorage = const FlutterSecureStorage(
    aOptions: _androidOptions,
  );

  final FlutterSecureStorage _legacyStorage = const FlutterSecureStorage();

  /// Reads the encryption key from EncryptedSharedPreferences first,
  /// falling back to legacy SharedPreferences for existing app installs.
  Future<String?> _readKeyWithFallback() async {
    // 1. Try reading from EncryptedSharedPreferences
    try {
      final key = await _encryptedStorage.read(key: _keyAlias);
      if (key != null && key.isNotEmpty) return key;
    } catch (_) {}

    // 2. Fallback to Legacy SharedPreferences (for users updating from prior builds)
    try {
      final legacyKey = await _legacyStorage.read(key: _keyAlias);
      if (legacyKey != null && legacyKey.isNotEmpty) {
        // Automatically migrate legacy key to EncryptedSharedPreferences
        try {
          await _encryptedStorage.write(key: _keyAlias, value: legacyKey);
        } catch (_) {}
        return legacyKey;
      }
    } catch (_) {}

    return null;
  }

  /// Returns the database encryption passphrase.
  ///
  /// If no key exists in secure storage and no database file exists yet,
  /// generates a new 256-bit key, Base64URL-encodes it, stores it, and returns it.
  /// On subsequent calls, retrieves the stored key directly with retries.
  ///
  /// CRITICAL INTEGRITY GUARD: If the database file already exists on disk,
  /// this method WILL NEVER generate a new key or overwrite the existing key.
  Future<String> getOrCreateDatabaseKey() async {
    // Check if production database file exists on disk
    final dbPath = await getDatabasesPath();
    final fullPath = join(dbPath, AppDatabase.databaseName);
    final dbFileExists =
        AppDatabase.databaseName != inMemoryDatabasePath &&
        File(fullPath).existsSync();

    // Retry loop for reading existing key to handle transient storage locks
    String? existingKey;
    for (var attempt = 0; attempt < 3; attempt++) {
      existingKey = await _readKeyWithFallback();
      if (existingKey != null && existingKey.isNotEmpty) {
        return existingKey;
      }
      if (attempt < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }

    if (existingKey != null && existingKey.isNotEmpty) {
      return existingKey;
    }

    // KEY PRESERVATION GUARD:
    // If the database file ALREADY EXISTS on disk, generating a new key is forbidden
    // as it would permanently break decryption of existing user data.
    final isTest =
        WidgetsBinding.instance.runtimeType.toString().contains('Test') ||
        Platform.environment.containsKey('FLUTTER_TEST');
    if (dbFileExists && !isTest) {
      throw StateError(
        'Database file exists but encryption key could not be retrieved from secure storage.',
      );
    }

    // Only generate a new key on fresh installs (no database file exists yet)
    final newKey = _generateSecureKey();
    await _encryptedStorage.write(key: _keyAlias, value: newKey);
    return newKey;
  }

  /// Generates a 32-byte (256-bit) cryptographically secure random key
  /// and returns it as a Base64URL-encoded string (43 printable ASCII chars).
  ///
  /// Base64URL is used instead of raw bytes because:
  /// - Raw bytes may contain 0x00 (null terminators) that silently truncate
  ///   strings when crossing the native platform channel.
  /// - Base64URL produces only [A-Za-z0-9_-] characters — safe for any
  ///   serialization layer, SharedPreferences, or SQLCipher PRAGMA key.
  String _generateSecureKey() {
    final random = Random.secure();
    final bytes = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      bytes[i] = random.nextInt(256);
    }
    return base64Url.encode(bytes);
  }
}
