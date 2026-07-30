import 'dart:io';
import 'package:expense_tracker/core/database/app_database.dart';
import 'package:expense_tracker/core/models/transaction.dart';
import 'package:expense_tracker/core/services/notification_log_service.dart';
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
      setState(() => _reminderTime = picked);
      await ReminderNotificationService.instance.setReminderTime(picked);
      if (mounted) AppToast.show(context, 'Daily reminder time updated');
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
      final fileName =
          'Expenses_Export_${DateTime.now().millisecondsSinceEpoch}.csv';
      tempFile = File('${tempDir.path}/$fileName');
      await tempFile.writeAsString(buffer.toString());

      try {
        await Share.shareXFiles([
          XFile(tempFile.path),
        ], text: 'My Expenses Ledger Export');
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

  Future<void> _exportNotificationLogs() async {
    try {
      await NotificationLogService.instance.exportLog();
    } catch (e) {
      if (!mounted) return;
      AppToast.show(context, 'Failed to export logs: $e', isError: true);
    }
  }

  Future<void> _clearNotificationLogs() async {
    await NotificationLogService.instance.clearLog();
    if (mounted) {
      AppToast.show(context, 'Notification logs cleared');
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
                            color: AppTheme.primaryBlue.withOpacity(0.12),
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
                        onChanged: (val) async {
                          setState(() => _isReminderEnabled = val);
                          await ReminderNotificationService.instance
                              .setReminderEnabled(val);
                          if (mounted) {
                            AppToast.show(
                              context,
                              val
                                  ? 'Daily reminder enabled'
                                  : 'Daily reminder disabled',
                            );
                          }
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
                              color: AppTheme.successGreen.withOpacity(0.12),
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
                                ? AppTheme.successGreen.withOpacity(0.12)
                                : AppTheme.errorRed.withOpacity(0.12),
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
                            color: AppTheme.primaryBlue.withOpacity(0.12),
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
                            color: AppTheme.coralAccent.withOpacity(0.12),
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
                      const Divider(height: 1, indent: 16, endIndent: 16),
                      ListTile(
                        contentPadding: const EdgeInsets.all(16),
                        leading: Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: AppTheme.warningAmber.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: const Icon(
                            Icons.bug_report_rounded,
                            color: AppTheme.warningAmber,
                          ),
                        ),
                        title: const Text(
                          'Export Notification Logs',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: AppTheme.textDark,
                            fontSize: 16,
                          ),
                        ),
                        subtitle: const Padding(
                          padding: EdgeInsets.only(top: 4),
                          child: Text(
                            'Share raw logs of all notification events for debugging',
                            style: TextStyle(
                              color: AppTheme.textMuted,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        trailing: const Icon(
                          Icons.share_rounded,
                          color: AppTheme.textMuted,
                        ),
                        onTap: _exportNotificationLogs,
                      ),
                      const Divider(height: 1, indent: 16, endIndent: 16),
                      ListTile(
                        contentPadding: const EdgeInsets.all(16),
                        leading: Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: AppTheme.errorRed.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: const Icon(
                            Icons.delete_sweep_rounded,
                            color: AppTheme.errorRed,
                          ),
                        ),
                        title: const Text(
                          'Clear Notification Logs',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: AppTheme.textDark,
                            fontSize: 16,
                          ),
                        ),
                        subtitle: const Padding(
                          padding: EdgeInsets.only(top: 4),
                          child: Text(
                            'Delete all stored diagnostic log entries',
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
                        onTap: _clearNotificationLogs,
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
                    const SizedBox(height: 4),
                    Text(
                      'Expense Tracker v1.0.1 (Build 2)',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppTheme.textMuted.withOpacity(0.7),
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
