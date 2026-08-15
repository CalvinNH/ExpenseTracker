import 'dart:async';
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
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  bool _isReminderEnabled = false;
  bool _isReminderUpdating = false;
  TimeOfDay _reminderTime = const TimeOfDay(hour: 21, minute: 0);
  bool? _isListenerConnected;
  bool _isReconnecting = false;
  NotificationCaptureStatus? _captureStatus;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadReminderSettings();
    _checkListenerStatus();
  }

  Future<void> _checkListenerStatus() async {
    try {
      final status = await NotificationService.getCaptureStatus();
      if (mounted) {
        setState(() {
          _isListenerConnected =
              status.accessGranted && status.listenerConnected;
          _captureStatus = status;
        });
      }
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(NotificationService.handleAppResumed());
      unawaited(_checkListenerStatus());
    }
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
    WidgetsBinding.instance.removeObserver(this);
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
      final captureStatus = await NotificationService.getCaptureStatus();
      final payload = const JsonEncoder.withIndent('  ').convert({
        'schemaVersion': 3,
        'exportedAt': DateTime.now().toUtc().toIso8601String(),
        'privacy':
            'Coarse allowlisted telemetry only; no notification text, values, identifiers, or content-derived fingerprints',
        'notificationCapture': captureStatus.toExportMap(),
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
    } catch (_) {
      if (mounted) {
        AppToast.show(
          context,
          'Reconnect failed. Toggle Notification Access off and on in '
          'Android Settings, then try again.',
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _isReconnecting = false);
    }
  }

  Future<void> _openNotificationSettings() async {
    await NotificationService.requestNotificationPermission();
  }

  Future<void> _reviewAndAcknowledgeCaptureHealth() async {
    final status = _captureStatus;
    if (status == null || !status.hasAcknowledgementEligibleIncidents) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Review capture incidents'),
        content: Text(
          '${status.capacityRejectedSinceAcknowledgement} rejected, '
          '${status.capacityEvictedSinceAcknowledgement} evicted, '
          '${status.storageFailuresSinceAcknowledgement + status.recoveryFailuresSinceAcknowledgement} storage/recovery, and '
          '${status.workerRetriesSinceAcknowledgement + status.workerFailuresSinceAcknowledgement + status.workerDeferredLockedSinceAcknowledgement} background-worker incident(s) since your last review. '
          'Acknowledging keeps the lifetime totals and does not hide current work or failures.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Acknowledge reviewed'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final updated = await NotificationService.acknowledgeCaptureHealth();
      if (!mounted) return;
      setState(() => _captureStatus = updated);
      AppToast.show(context, 'Capture incidents marked as reviewed');
    } catch (_) {
      if (mounted) {
        AppToast.show(
          context,
          'Could not acknowledge capture health. Refresh and try again.',
          isError: true,
        );
      }
    }
  }

  String _captureHealthDescription() {
    final status = _captureStatus;
    if (status == null || !status.isAvailable) {
      return 'Open the app on Android to load capture health.';
    }
    if (!status.readSucceeded) {
      return 'The native inbox could not be read. Refresh now; export diagnostics if this repeats.';
    }
    if (!status.accessGranted) {
      return 'Notification access is disabled. Tap here to enable it in Android Settings.';
    }
    if (!status.listenerConnected) {
      return 'Android has not connected the listener. Tap here to reconnect it.';
    }
    if (status.deadLetterCount > 0 || status.quarantinedCount > 0) {
      return '${status.quarantinedCount} quarantined and '
          '${status.deadLetterCount} unreadable capture(s). Export diagnostics for review.';
    }
    if (status.capacityRejectedSinceAcknowledgement > 0 ||
        status.capacityEvictedSinceAcknowledgement > 0) {
      return '${status.capacityRejectedSinceAcknowledgement} rejected and '
          '${status.capacityEvictedSinceAcknowledgement} evicted capture(s) since review. Review and acknowledge below.';
    }
    if (status.storageFailuresSinceAcknowledgement > 0 ||
        status.recoveryFailuresSinceAcknowledgement > 0) {
      return '${status.storageFailuresSinceAcknowledgement} storage and ${status.recoveryFailuresSinceAcknowledgement} recovery incident(s) since review. Export diagnostics, then acknowledge.';
    }
    if (status.workerRetriesSinceAcknowledgement > 0 ||
        status.workerFailuresSinceAcknowledgement > 0 ||
        status.workerDeferredLockedSinceAcknowledgement > 0) {
      return 'Background processing recorded a retry, failure, or locked-device delay. Refresh after the inbox clears, then acknowledge.';
    }
    if (status.legacyMigrationPending > 0) {
      return '${status.legacyMigrationPending} legacy capture(s) still need migration.';
    }
    if (status.retryingCount > 0) {
      return '${status.retryingCount} capture(s) are waiting for a safe retry.';
    }
    if (status.hasStaleBacklogAt(DateTime.now())) {
      return 'Capture processing is taking too long. Keep the device unlocked, refresh, then export diagnostics if it remains stuck.';
    }
    if (status.pendingCount > 0 || status.leasedCount > 0) {
      return '${status.pendingCount} pending and ${status.leasedCount} processing capture(s).';
    }
    return 'Inbox clear. ${status.acknowledgedCount} capture(s) safely processed.';
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
                        onTap: _captureStatus?.accessGranted == false
                            ? _openNotificationSettings
                            : (_captureStatus?.listenerConnected == false
                                  ? _reconnectListener
                                  : _checkListenerStatus),
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
                            color: (_captureStatus?.needsAttention ?? true)
                                ? AppTheme.coralAccent.withValues(alpha: 0.12)
                                : AppTheme.successGreen.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Icon(
                            (_captureStatus?.needsAttention ?? true)
                                ? Icons.monitor_heart_outlined
                                : Icons.inbox_rounded,
                            color: (_captureStatus?.needsAttention ?? true)
                                ? AppTheme.coralAccent
                                : AppTheme.successGreen,
                          ),
                        ),
                        title: Text(
                          _captureStatus == null
                              ? 'Capture health: Checking'
                              : (_captureStatus!.needsAttention
                                    ? 'Capture health: Needs attention'
                                    : 'Capture health: Healthy'),
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            color: AppTheme.textDark,
                            fontSize: 16,
                          ),
                        ),
                        onTap: _captureStatus?.accessGranted == false
                            ? _openNotificationSettings
                            : (_captureStatus?.listenerConnected == false
                                  ? _reconnectListener
                                  : _checkListenerStatus),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            _captureHealthDescription(),
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
                          tooltip: 'Refresh capture health',
                        ),
                      ),
                      if (_captureStatus?.hasAcknowledgementEligibleIncidents ??
                          false)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: TextButton.icon(
                              onPressed: _reviewAndAcknowledgeCaptureHealth,
                              icon: const Icon(Icons.fact_check_outlined),
                              label: const Text('Review and acknowledge'),
                            ),
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
