import 'dart:io';

import 'package:sqflite_sqlcipher/sqflite.dart';

enum DatabaseFileState { absent, encrypted, plaintext, unreadable }

class DatabaseMigrationException implements Exception {
  const DatabaseMigrationException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'DatabaseMigrationException($code): $message';
}

/// Detects the database from its contents instead of trusting a preference
/// flag, and migrates plaintext databases without ever deleting the only
/// known-good copy.
class DatabaseMigrator {
  DatabaseMigrator._();

  static final DatabaseMigrator instance = DatabaseMigrator._();

  static const _temporarySuffix = '.encrypting';
  static const _backupSuffix = '.pre_encryption_backup';

  Future<DatabaseFileState> prepare(String dbPath, String passphrase) async {
    _validatePassphrase(passphrase);
    await _recoverInterruptedSwap(dbPath, passphrase);

    final state = await inspect(dbPath, passphrase);
    switch (state) {
      case DatabaseFileState.absent:
      case DatabaseFileState.encrypted:
        return state;
      case DatabaseFileState.plaintext:
        await _performEncryptionMigration(dbPath, passphrase);
        return DatabaseFileState.encrypted;
      case DatabaseFileState.unreadable:
        throw const DatabaseMigrationException(
          'database_unreadable',
          'The database exists but cannot be decrypted or validated. '
              'The original file has been preserved.',
        );
    }
  }

  Future<DatabaseFileState> inspect(String dbPath, String passphrase) async {
    if (!File(dbPath).existsSync()) return DatabaseFileState.absent;
    if (await _canReadEncrypted(dbPath, passphrase)) {
      return DatabaseFileState.encrypted;
    }
    if (await _canReadPlaintext(dbPath)) {
      return DatabaseFileState.plaintext;
    }
    return DatabaseFileState.unreadable;
  }

  Future<void> _recoverInterruptedSwap(String dbPath, String passphrase) async {
    final production = File(dbPath);
    final temporary = File('$dbPath$_temporarySuffix');
    final backup = File('$dbPath$_backupSuffix');

    if (!production.existsSync() && backup.existsSync()) {
      await backup.rename(dbPath);
    }

    if (production.existsSync() && backup.existsSync()) {
      final productionState = await inspect(dbPath, passphrase);
      if (productionState == DatabaseFileState.encrypted) {
        await backup.delete();
      } else {
        final backupState = await inspect(backup.path, passphrase);
        if (backupState == DatabaseFileState.encrypted ||
            backupState == DatabaseFileState.plaintext) {
          final unreadablePath =
              '$dbPath.unreadable.${DateTime.now().millisecondsSinceEpoch}';
          await production.rename(unreadablePath);
          await backup.rename(dbPath);
        }
      }
    }

    if (temporary.existsSync()) {
      final productionState = await inspect(dbPath, passphrase);
      if (productionState == DatabaseFileState.encrypted) {
        await temporary.delete();
      } else {
        final temporaryState = await inspect(temporary.path, passphrase);
        if (!production.existsSync() &&
            temporaryState == DatabaseFileState.encrypted) {
          await temporary.rename(dbPath);
        } else {
          await temporary.delete();
        }
      }
    }
  }

  Future<void> _performEncryptionMigration(
    String dbPath,
    String passphrase,
  ) async {
    final temporaryPath = '$dbPath$_temporarySuffix';
    final backupPath = '$dbPath$_backupSuffix';
    final temporary = File(temporaryPath);
    final backup = File(backupPath);
    if (temporary.existsSync()) await temporary.delete();
    await _deleteSidecars(temporaryPath);
    if (backup.existsSync()) await backup.delete();

    final plaintext = await openDatabase(dbPath);
    var attached = false;
    try {
      // Consolidate WAL content before the file-level swap.
      await plaintext.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
      await plaintext.execute(
        "ATTACH DATABASE '${_sqlLiteral(temporaryPath)}' "
        "AS encrypted KEY '${_sqlLiteral(passphrase)}'",
      );
      attached = true;
      await plaintext.rawQuery("SELECT sqlcipher_export('encrypted')");
      await plaintext.execute('DETACH DATABASE encrypted');
      attached = false;
    } finally {
      if (attached) {
        try {
          await plaintext.execute('DETACH DATABASE encrypted');
        } catch (_) {
          // Closing the connection releases the attachment.
        }
      }
      await plaintext.close();
    }

    if (!await _canReadEncrypted(temporaryPath, passphrase)) {
      if (temporary.existsSync()) await temporary.delete();
      throw const DatabaseMigrationException(
        'encrypted_export_invalid',
        'The encrypted copy did not pass validation; the original is intact.',
      );
    }

    await _deleteSidecars(dbPath);
    final production = File(dbPath);
    await production.rename(backupPath);
    try {
      await temporary.rename(dbPath);
      if (!await _canReadEncrypted(dbPath, passphrase)) {
        throw const DatabaseMigrationException(
          'promoted_database_invalid',
          'The promoted encrypted database did not pass validation.',
        );
      }
      await backup.delete();
    } catch (_) {
      if (File(dbPath).existsSync()) {
        await File(dbPath).delete();
      }
      if (backup.existsSync()) {
        await backup.rename(dbPath);
      }
      rethrow;
    }
  }

  Future<bool> _canReadEncrypted(String path, String passphrase) async {
    Database? db;
    try {
      db = await openDatabase(path, password: passphrase, readOnly: true);
      await db.rawQuery('SELECT count(*) FROM sqlite_master');
      final quickCheck = await db.rawQuery('PRAGMA quick_check(1)');
      if (quickCheck.isEmpty ||
          quickCheck.first.values.first.toString().toLowerCase() != 'ok') {
        return false;
      }
      final cipherCheck = await db.rawQuery('PRAGMA cipher_integrity_check');
      return cipherCheck.isEmpty &&
          quickCheck.isNotEmpty &&
          quickCheck.first.values.first.toString().toLowerCase() == 'ok';
    } catch (_) {
      return false;
    } finally {
      if (db?.isOpen ?? false) await db!.close();
    }
  }

  Future<bool> _canReadPlaintext(String path) async {
    Database? db;
    try {
      db = await openDatabase(path, readOnly: true);
      await db.rawQuery('SELECT count(*) FROM sqlite_master');
      final quickCheck = await db.rawQuery('PRAGMA quick_check(1)');
      return quickCheck.isNotEmpty &&
          quickCheck.first.values.first.toString().toLowerCase() == 'ok';
    } catch (_) {
      return false;
    } finally {
      if (db?.isOpen ?? false) await db!.close();
    }
  }

  Future<void> _deleteSidecars(String path) async {
    for (final suffix in const ['-journal', '-wal', '-shm']) {
      final file = File('$path$suffix');
      if (file.existsSync()) await file.delete();
    }
  }

  void _validatePassphrase(String value) {
    if (!RegExp(r'^[A-Za-z0-9_-]{43}=?$').hasMatch(value)) {
      throw const DatabaseMigrationException(
        'invalid_key_material',
        'Database key material has an invalid format.',
      );
    }
  }

  String _sqlLiteral(String value) => value.replaceAll("'", "''");
}
