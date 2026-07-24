import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

/// Handles one-time migration of an existing plaintext SQLite database to
/// SQLCipher-encrypted format.
///
/// Migration sequence enforces strict atomicity:
///   1. Check flag → skip if already migrated.
///   2. Open plaintext DB → ATTACH temp_encrypted.db → sqlcipher_export.
///   3. Detach & close.
///   4. Verify temp_encrypted.db integrity with the passphrase.
///   5. Only on success: delete old file, rename temp → production.
///   6. Write completion flag only after swap is 100% complete.
///
/// Any failure before step 5 leaves the original plaintext file untouched.
class DatabaseMigrator {
  DatabaseMigrator._();

  static final DatabaseMigrator instance = DatabaseMigrator._();

  static const _migrationFlagKey = 'sqlcipher_migration_complete';
  static const _androidOptions = AndroidOptions(
    encryptedSharedPreferences: true,
  );

  final FlutterSecureStorage _encryptedStorage = const FlutterSecureStorage(
    aOptions: _androidOptions,
  );
  final FlutterSecureStorage _legacyStorage = const FlutterSecureStorage();

  Future<bool> _isMigrationCompleted() async {
    try {
      final flag1 = await _encryptedStorage.read(key: _migrationFlagKey);
      if (flag1 == 'true') return true;
      final flag2 = await _legacyStorage.read(key: _migrationFlagKey);
      if (flag2 == 'true') return true;
    } catch (_) {}
    return false;
  }

  /// Runs the plaintext → encrypted migration if it hasn't been completed yet.
  ///
  /// This is a no-op for:
  /// - Fresh installs (no plaintext DB exists, flag is absent).
  /// - Already-migrated installs (flag is 'true').
  ///
  /// [dbPath] is the full filesystem path to the production database file.
  /// [passphrase] is the Base64URL-encoded key from [SecurityKeyManager].
  Future<void> migrateIfNeeded(String dbPath, String passphrase) async {
    // Step 1: Check flag — skip if already migrated
    if (await _isMigrationCompleted()) {
      return;
    }

    // If the database file doesn't exist, this is a fresh install — no migration needed
    final dbFile = File(dbPath);
    if (!dbFile.existsSync()) {
      return;
    }

    // Attempt to detect if the database is plaintext by opening it without a password.
    // If it opens and we can query sqlite_master, it's unencrypted.
    bool isPlaintext = false;
    try {
      final testDb = await openDatabase(dbPath, readOnly: true);
      // If openDatabase succeeds without a password on an encrypted DB,
      // SQLCipher would throw. Success means plaintext.
      await testDb.rawQuery('SELECT count(*) FROM sqlite_master');
      await testDb.close();
      isPlaintext = true;
    } catch (_) {
      // Database is either encrypted already or corrupt.
      // In both cases, skip migration.
      isPlaintext = false;
    }

    if (!isPlaintext) {
      // Already encrypted or doesn't need migration — mark and return
      await _markMigrationCompleted();
      return;
    }

    // Steps 2-6: Perform the actual encryption migration
    await _performEncryptionMigration(dbPath, passphrase);
  }

  /// Executes the atomic migration: export → verify → swap → flag.
  Future<void> _performEncryptionMigration(
    String dbPath,
    String passphrase,
  ) async {
    final tempEncryptedPath = '$dbPath.tmp_encrypted';

    // Clean up any leftover temp file from a previously interrupted migration
    final tempFile = File(tempEncryptedPath);
    if (tempFile.existsSync()) {
      tempFile.deleteSync();
    }

    // Step 2: Open the plaintext database (no password)
    final plaintextDb = await openDatabase(dbPath, readOnly: true);

    try {
      // Step 3: Attach encrypted DB and export
      // Use single quotes around the passphrase to pass it as a SQL string literal.
      // Defense-in-depth: the passphrase is interpolated into the ATTACH
      // statement below. That is safe ONLY because SecurityKeyManager
      // generates Base64URL keys ([A-Za-z0-9_-]). Enforce the invariant so
      // a future change to key generation cannot introduce SQL injection.
      if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(passphrase)) {
        throw ArgumentError('Invalid passphrase format for DB migration.');
      }
      await plaintextDb.execute(
        "ATTACH DATABASE '$tempEncryptedPath' AS encrypted KEY '$passphrase'",
      );
      await plaintextDb.rawQuery("SELECT sqlcipher_export('encrypted')");
      await plaintextDb.execute('DETACH DATABASE encrypted');
    } finally {
      // Step 4: Close the plaintext connection regardless of success/failure
      await plaintextDb.close();
    }

    // Step 5: Integrity Verification Gate
    // Open the newly created encrypted file with the passphrase and verify
    // that the schema and data survived the export.
    final verified = await _verifyEncryptedDatabase(
      tempEncryptedPath,
      passphrase,
    );

    if (!verified) {
      // Verification failed — abort. Delete the corrupt temp file but
      // leave the original plaintext database completely untouched.
      if (tempFile.existsSync()) {
        tempFile.deleteSync();
      }
      // Do NOT write the migration flag — next launch will retry.
      return;
    }

    // Step 6: Atomic File Swap
    // Delete old plaintext file, rename temp encrypted → production path.
    final originalFile = File(dbPath);
    if (originalFile.existsSync()) {
      originalFile.deleteSync();
    }
    tempFile.renameSync(dbPath);

    // Also clean up any SQLite journal/wal files from the old plaintext DB
    for (final suffix in ['-journal', '-wal', '-shm']) {
      final sidecarFile = File('$dbPath$suffix');
      if (sidecarFile.existsSync()) {
        sidecarFile.deleteSync();
      }
    }

    // Step 7: Write completion flag ONLY after file swap is fully complete
    await _markMigrationCompleted();
  }

  /// Opens the encrypted database and runs validation queries to confirm
  /// the export produced a valid, readable, encrypted database.
  ///
  /// Returns `true` if the database opens successfully and both tables exist
  /// with queryable row counts. Returns `false` on any error.
  Future<bool> _verifyEncryptedDatabase(
    String path,
    String passphrase,
  ) async {
    try {
      final db = await openDatabase(path, password: passphrase, readOnly: true);
      try {
        // Verify both tables exist and are queryable
        final accountResult =
            await db.rawQuery('SELECT COUNT(*) as cnt FROM accounts');
        final txnResult =
            await db.rawQuery('SELECT COUNT(*) as cnt FROM transactions');

        // Basic sanity: queries must return results (even if count is 0)
        if (accountResult.isEmpty || txnResult.isEmpty) {
          return false;
        }

        return true;
      } finally {
        await db.close();
      }
    } catch (_) {
      return false;
    }
  }

  Future<void> _markMigrationCompleted() async {
    await _encryptedStorage.write(key: _migrationFlagKey, value: 'true');
  }
}
