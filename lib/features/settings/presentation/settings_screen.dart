import 'dart:convert';
import 'dart:io';
import 'package:expense_tracker/core/database/app_database.dart';
import 'package:expense_tracker/core/models/transaction.dart';
import 'package:expense_tracker/core/services/reminder_notification_service.dart';
import 'package:expense_tracker/core/theme/app_theme.dart';
import 'package:expense_tracker/core/widgets/app_toast.dart';
import 'package:expense_tracker/features/dashboard/presentation/accounts_screen.dart';
import 'package:expense_tracker/features/ingestion/notification_service.dart';
import 'package:flutter/material.dart';
import 'package:notification_listener_service/notification_listener_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _isReminderEnabled = false;
  bool _isReminderUpdating = false;
  TimeOfDay _reminderTime = const TimeOfDay(hour: 21, minute: 0);
  bool? _isListenerConnected;
  bool _isReconnecting = false;

  @override
  void initState() {
    super.initState();
    _loadReminderSettings();
    _checkListenerStatus();
  }

  Future<void> _checkListenerStatus() async {
    try {
      final isGranted = await NotificationListenerService.isPermissionGranted();
      final isConnected = await NotificationService.isServiceConnected();
      if (mounted) {
        setState(() {
          _isListenerConnected = isGranted && isConnected;
        });
      }
    } catch (_) {}
  }

  Future<void> _loadReminderSettings() async {
    final enabled = await ReminderNotificationService.instance
        .isReminderEnabled();
    final time = await ReminderNotificationService.instance.getReminderTime();
    if (mounted) {
      setState(() {
        _isReminderEnabled = enabled;
        _reminderTime = time;
      });
    }
  }

  Future<void> _selectReminderTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _reminderTime,
    );
    if (picked != null && mounted) {
      final updated = await ReminderNotificationService.instance
          .setReminderTime(picked);
      if (!mounted) return;
      if (updated) {
        setState(() => _reminderTime = picked);
      }
      AppToast.show(
        context,
        updated
            ? 'Daily reminder time updated'
            : 'Could not update the reminder time',
      );
    }
  }

  String _formatReminderTime(TimeOfDay time) {
    final period = time.hour >= 12 ? 'PM' : 'AM';
    final hour = time.hour > 12
        ? time.hour - 12
        : (time.hour == 0 ? 12 : time.hour);
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute $period';
  }

  @override
  void dispose() {
    super.dispose();
  }

  String _escapeCsvField(String field) {
    var value = field;
    // Neutralize spreadsheet formula injection (OWASP): cells starting
    // with =, +, -, @, tab, or CR are prefixed with a single quote so
    // Excel/Sheets treat them as text, not formulas.
    if (value.isNotEmpty && '=+-@\t\r'.contains(value[0])) {
      value = "'$value";
    }
    if (value.contains(',') || value.contains('"') || value.contains('\n')) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
  }

  Future<void> _deleteStaleCsvExports(Directory tempDirectory) async {
    try {
      await for (final entity in tempDirectory.list(followLinks: false)) {
        final segments = entity.uri.pathSegments;
        final name = segments.isEmpty ? '' : segments.last;
        if (entity is File &&
            name.startsWith('Expenses_Export_') &&
            name.endsWith('.csv')) {
          await entity.delete();
        }
      }
    } catch (_) {
      // Best-effort cleanup must not block an explicit user export.
    }
  }

  Future<void> _exportToCsv() async {
    File? tempFile;
    try {
      final db = AppDatabase.instance;
      final allTransactions = await db.getAllTransactions();
      final allAccounts = await db.getAllAccounts();

      final accountMap = {for (final acc in allAccounts) acc.id!: acc.bankName};

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
      await _deleteStaleCsvExports(tempDir);
      final fileName =
          'Expenses_Export_${DateTime.now().millisecondsSinceEpoch}.csv';
      tempFile = File('${tempDir.path}${Platform.pathSeparator}$fileName');
      await tempFile.writeAsString(buffer.toString());

      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(tempFile.path)],
          text: 'My Expenses Ledger Export',
        ),
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.show(context, 'Export failed: $e', isError: true);
    } finally {
      final file = tempFile;
      if (file != null) {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
    }
  }

  Future<void> _exportParserDiagnostics() async {
    File? tempFile;
    try {
      final diagnostics = await AppDatabase.instance.getParserDiagnostics();
      final payload = const JsonEncoder.withIndent('  ').convert({
        'schemaVersion': 1,
        'exportedAt': DateTime.now().toUtc().toIso8601String(),
        'privacy': 'No raw notification text or extracted financial values',
        'diagnostics': diagnostics
            .map((diagnostic) => diagnostic.toExportMap())
            .toList(growable: false),
      });
      final tempDir = await getTemporaryDirectory();
      await for (final entity in tempDir.list(followLinks: false)) {
        final segments = entity.uri.pathSegments;
        final name = segments.isEmpty ? '' : segments.last;
        if (entity is File &&
            name.startsWith('Parser_Diagnostics_') &&
            name.endsWith('.json')) {
          await entity.delete();
        }
      }
      final fileName =
          'Parser_Diagnostics_${DateTime.now().millisecondsSinceEpoch}.json';
      tempFile = File('${tempDir.path}${Platform.pathSeparator}$fileName');
      await tempFile.writeAsString(payload, flush: true);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(tempFile.path)],
          text: 'Redacted local parser diagnostics',
        ),
      );
    } catch (_) {
      if (mounted) {
        AppToast.show(context, 'Diagnostics export failed', isError: true);
      }
    } finally {
      final file = tempFile;
      if (file != null) {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
    }
  }

  Future<void> _reconnectListener() async {
    setState(() => _isReconnecting = true);
    try {
      final success = await NotificationService.reconnectService();
      await _checkListenerStatus();
      if (mounted) {
        AppToast.show(
          context,
          success
              ? 'Notification Listener reconnected!'
              : 'Reconnect attempted. Toggle Notification Access OFF and ON in Android Settings if issues persist.',
        );
      }
    } catch (e) {
      if (mounted) {
        AppToast.show(context, 'Reconnect failed: $e', isError: true);
      }
    } finally {
      if (mounted) setState(() => _isReconnecting = false);
    }
  }

  Future<void> _openNotificationSettings() async {
    await NotificationListenerService.requestPermission();
    await _checkListenerStatus();
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
                child: Material(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(20),
                  clipBehavior: Clip.antiAlias,
                  child: ListTile(
                    contentPadding: const EdgeInsets.all(16),
                    leading: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: AppTheme.primaryBlue.withValues(alpha: 0.12),
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
                        'Share a CSV copy using an app you choose',
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
              ),
              const SizedBox(height: 12),
              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: AppTheme.cardShadow,
                ),
                child: Material(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(20),
                  clipBehavior: Clip.antiAlias,
                  child: ListTile(
                    contentPadding: const EdgeInsets.all(16),
                    leading: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: AppTheme.successGreen.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const Icon(
                        Icons.bug_report_outlined,
                        color: AppTheme.successGreen,
                      ),
                    ),
                    title: const Text(
                      'Export Parser Diagnostics',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: AppTheme.textDark,
                        fontSize: 16,
                      ),
                    ),
                    subtitle: const Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Text(
                        'Share redacted, value-free local parser decisions',
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
                    onTap: _exportParserDiagnostics,
                  ),
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
                child: Material(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(20),
                  clipBehavior: Clip.antiAlias,
                  child: ListTile(
                    contentPadding: const EdgeInsets.all(16),
                    leading: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: AppTheme.coralAccent.withValues(alpha: 0.12),
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
                        MaterialPageRoute<void>(
                          builder: (_) => const AccountsScreen(),
                        ),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 28),

              // Daily Reminder Section
              const Text(
                'Notifications',
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
                child: Material(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(20),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      SwitchListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        secondary: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: AppTheme.primaryBlue.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: const Icon(
                            Icons.notifications_active_rounded,
                            color: AppTheme.primaryBlue,
                          ),
                        ),
                        title: const Text(
                          'Daily Manual Entry Reminder',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: AppTheme.textDark,
                            fontSize: 15,
                          ),
                        ),
                        subtitle: const Padding(
                          padding: EdgeInsets.only(top: 4),
                          child: Text(
                            'Reminds you to add missed transactions daily',
                            style: TextStyle(
                              color: AppTheme.textMuted,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        value: _isReminderEnabled,
                        onChanged: _isReminderUpdating
                            ? null
                            : (val) async {
                                setState(() => _isReminderUpdating = true);
                                final result = await ReminderNotificationService
                                    .instance
                                    .setReminderEnabled(val);
                                if (!context.mounted) return;

                                setState(() {
                                  _isReminderUpdating = false;
                                  if (result == ReminderUpdateResult.enabled) {
                                    _isReminderEnabled = true;
                                  } else if (result ==
                                          ReminderUpdateResult.disabled ||
                                      result ==
                                          ReminderUpdateResult
                                              .permissionDenied) {
                                    _isReminderEnabled = false;
                                  }
                                });

                                final message = switch (result) {
                                  ReminderUpdateResult.enabled =>
                                    'Daily reminder enabled',
                                  ReminderUpdateResult.disabled =>
                                    'Daily reminder disabled',
                                  ReminderUpdateResult.permissionDenied =>
                                    'Notification permission is required for reminders',
                                  ReminderUpdateResult.failed =>
                                    'Could not update the daily reminder',
                                };
                                AppToast.show(context, message);
                              },
                      ),
                      if (_isReminderEnabled) ...[
                        const Divider(height: 1, indent: 16, endIndent: 16),
                        ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          leading: Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: AppTheme.successGreen.withValues(
                                alpha: 0.12,
                              ),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: const Icon(
                              Icons.access_time_rounded,
                              color: AppTheme.successGreen,
                            ),
                          ),
                          title: const Text(
                            'Reminder Time',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: AppTheme.textDark,
                              fontSize: 15,
                            ),
                          ),
                          subtitle: Text(
                            _formatReminderTime(_reminderTime),
                            style: const TextStyle(
                              color: AppTheme.primaryBlue,
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                          trailing: const Icon(
                            Icons.edit_outlined,
                            color: AppTheme.textMuted,
                            size: 20,
                          ),
                          onTap: _selectReminderTime,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 28),

              // Diagnostics Section
              const Text(
                'Diagnostics & System Listener',
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
                child: Material(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(20),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      // Listener Connection Status Badge
                      ListTile(
                        contentPadding: const EdgeInsets.all(16),
                        leading: Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: (_isListenerConnected == true)
                                ? AppTheme.successGreen.withValues(alpha: 0.12)
                                : AppTheme.errorRed.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Icon(
                            (_isListenerConnected == true)
                                ? Icons.check_circle_rounded
                                : Icons.warning_amber_rounded,
                            color: (_isListenerConnected == true)
                                ? AppTheme.successGreen
                                : AppTheme.errorRed,
                          ),
                        ),
                        title: Text(
                          (_isListenerConnected == true)
                              ? 'Listener Status: Active'
                              : 'Listener Status: Disconnected',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: (_isListenerConnected == true)
                                ? AppTheme.textDark
                                : AppTheme.errorRed,
                            fontSize: 16,
                          ),
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            (_isListenerConnected == true)
                                ? 'Android OS is actively forwarding notifications'
                                : 'Permission granted, but Android OS unbound the listener. Tap Reconnect.',
                            style: const TextStyle(
                              color: AppTheme.textMuted,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        trailing: IconButton(
                          icon: const Icon(
                            Icons.refresh_rounded,
                            color: AppTheme.primaryBlue,
                          ),
                          onPressed: _checkListenerStatus,
                          tooltip: 'Check Status',
                        ),
                      ),
                      const Divider(height: 1, indent: 16, endIndent: 16),
                      ListTile(
                        contentPadding: const EdgeInsets.all(16),
                        leading: Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: AppTheme.primaryBlue.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: _isReconnecting
                              ? const Padding(
                                  padding: EdgeInsets.all(12),
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                  ),
                                )
                              : const Icon(
                                  Icons.sync_rounded,
                                  color: AppTheme.primaryBlue,
                                ),
                        ),
                        title: const Text(
                          'Reconnect Notification Listener',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: AppTheme.textDark,
                            fontSize: 16,
                          ),
                        ),
                        subtitle: const Padding(
                          padding: EdgeInsets.only(top: 4),
                          child: Text(
                            'Force Android OS to re-bind the background listener service',
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
                        onTap: _isReconnecting ? null : _reconnectListener,
                      ),
                      const Divider(height: 1, indent: 16, endIndent: 16),
                      ListTile(
                        contentPadding: const EdgeInsets.all(16),
                        leading: Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: AppTheme.coralAccent.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: const Icon(
                            Icons.settings_suggest_rounded,
                            color: AppTheme.coralAccent,
                          ),
                        ),
                        title: const Text(
                          'Open Notification Access Settings',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: AppTheme.textDark,
                            fontSize: 16,
                          ),
                        ),
                        subtitle: const Padding(
                          padding: EdgeInsets.only(top: 4),
                          child: Text(
                            'Toggle Expense Tracker OFF & ON in Android settings if system unbinds listener',
                            style: TextStyle(
                              color: AppTheme.textMuted,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        trailing: const Icon(
                          Icons.open_in_new_rounded,
                          color: AppTheme.textMuted,
                        ),
                        onTap: _openNotificationSettings,
                      ),
                    ],
                  ),
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
                      color: AppTheme.primaryBlue.withValues(alpha: 0.6),
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
                    const SizedBox(height: 4),
                    Text(
                      'Expense Tracker v1.0.1 (Build 2)',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppTheme.textMuted.withValues(alpha: 0.7),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(
                height: 120,
              ), // Padding for the floating bottom bar
            ],
          ),
        ),
      ),
    );
  }
}
