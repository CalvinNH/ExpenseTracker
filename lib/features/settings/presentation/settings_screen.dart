import 'dart:io';
import 'package:expense_tracker/core/database/app_database.dart';
import 'package:expense_tracker/core/models/transaction.dart';
import 'package:expense_tracker/core/theme/app_theme.dart';
import 'package:expense_tracker/core/widgets/app_toast.dart';
import 'package:expense_tracker/features/dashboard/presentation/accounts_screen.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {

  @override
  void dispose() {
    super.dispose();
  }

  String _escapeCsvField(String field) {
    if (field.contains(',') || field.contains('"') || field.contains('\n')) {
      return '"${field.replaceAll('"', '""')}"';
    }
    return field;
  }

  Future<void> _exportToCsv() async {
    File? tempFile;
    try {
      final db = AppDatabase.instance;
      final allTransactions = await db.getAllTransactions();
      final allAccounts = await db.getAllAccounts();

      final accountMap = {
        for (final acc in allAccounts) acc.id!: acc.bankName,
      };

      final buffer = StringBuffer();
      buffer.writeln('Date,Merchant,Category,Type,Account,Amount');

      for (final txn in allTransactions) {
        final date = _escapeCsvField(txn.timestamp.toIso8601String());
        final merchant = _escapeCsvField(txn.merchant);
        final category = _escapeCsvField(txn.category);
        final type = txn.type == TransactionType.credit ? 'Credit' : 'Debit';
        final account = _escapeCsvField(accountMap[txn.accountId] ?? 'Unknown');
        final amount = txn.amount.toStringAsFixed(2);

        buffer.writeln('$date,$merchant,$category,$type,$account,$amount');
      }

      final tempDir = await getTemporaryDirectory();
      final fileName = 'Expenses_Export_${DateTime.now().millisecondsSinceEpoch}.csv';
      tempFile = File('${tempDir.path}/$fileName');
      await tempFile.writeAsString(buffer.toString());

      try {
        await Share.shareXFiles(
          [XFile(tempFile.path)],
          text: 'My Expenses Ledger Export',
        );
      } finally {
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
      }
    } catch (e) {
      if (!mounted) return;
      AppToast.show(context, 'Export failed: $e', isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 24),
              // Header
              Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: const BoxDecoration(
                      color: AppTheme.primaryBlue,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.settings_rounded,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Text(
                    'Settings',
                    style: theme.textTheme.displayLarge?.copyWith(
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.textDark,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 32),

              // Data Section
              const Text(
                'Data',
                style: TextStyle(
                  color: AppTheme.textDark,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: AppTheme.cardShadow,
                ),
                child: ListTile(
                  contentPadding: const EdgeInsets.all(16),
                  leading: Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: AppTheme.primaryBlue.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(
                      Icons.file_download_rounded,
                      color: AppTheme.primaryBlue,
                    ),
                  ),
                  title: const Text(
                    'Export to CSV',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: AppTheme.textDark,
                      fontSize: 16,
                    ),
                  ),
                  subtitle: const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Text(
                      'Choose a folder and save your transaction data',
                      style: TextStyle(
                        color: AppTheme.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  trailing: const Icon(
                    Icons.chevron_right_rounded,
                    color: AppTheme.textMuted,
                  ),
                  onTap: _exportToCsv,
                ),
              ),
              const SizedBox(height: 28),

              // Accounts Section
              const Text(
                'Accounts',
                style: TextStyle(
                  color: AppTheme.textDark,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: AppTheme.cardShadow,
                ),
                child: ListTile(
                  contentPadding: const EdgeInsets.all(16),
                  leading: Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: AppTheme.coralAccent.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(
                      Icons.account_balance_wallet_rounded,
                      color: AppTheme.coralAccent,
                    ),
                  ),
                  title: const Text(
                    'Add Account',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: AppTheme.textDark,
                      fontSize: 16,
                    ),
                  ),
                  subtitle: const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Text(
                      'Set up another cash, bank, or card account',
                      style: TextStyle(
                        color: AppTheme.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  trailing: const Icon(
                    Icons.chevron_right_rounded,
                    color: AppTheme.textMuted,
                  ),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute<void>(builder: (_) => const AccountsScreen()),
                    );
                  },
                ),
              ),
              const SizedBox(height: 48),

              // Privacy Notice
              Center(
                child: Column(
                  children: [
                    Icon(
                      Icons.shield_outlined,
                      size: 24,
                      color: AppTheme.primaryBlue.withOpacity(0.6),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Your financial data stays private on this device.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: AppTheme.textMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 120), // Padding for the floating bottom bar
            ],
          ),
        ),
      ),
    );
  }
}
