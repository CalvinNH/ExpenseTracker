import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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

  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  /// Returns the database encryption passphrase.
  ///
  /// If no key exists in secure storage, generates a new 256-bit key,
  /// Base64URL-encodes it, stores it, and returns the encoded string.
  /// On subsequent calls, retrieves the stored key directly.
  Future<String> getOrCreateDatabaseKey() async {
    final existingKey = await _storage.read(key: _keyAlias);
    if (existingKey != null && existingKey.isNotEmpty) {
      return existingKey;
    }

    final newKey = _generateSecureKey();
    await _storage.write(key: _keyAlias, value: newKey);
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
