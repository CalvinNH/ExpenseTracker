import 'dart:async';
import 'dart:ui';
import 'package:expense_tracker/core/database/app_database.dart';
import 'package:expense_tracker/core/models/account.dart';
import 'package:expense_tracker/core/models/transaction.dart';
import 'package:expense_tracker/core/services/notification_log_service.dart';
import 'package:expense_tracker/features/ingestion/notification_parser.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:notification_listener_service/notification_event.dart';
import 'package:notification_listener_service/notification_listener_service.dart';

class NotificationService {
  static StreamSubscription<ServiceNotificationEvent>? _subscription;
  static bool _isInitialized = false;
  static bool _isInitializing = false;

  static const MethodChannel _methodeChannel = MethodChannel(
    'x-slayer/notifications_channel',
  );
  static const MethodChannel _queueChannel = MethodChannel(
    'expense_tracker/notification_queue',
  );

  // Static broadcast stream controller to notify UI of background transaction ingestions
  static final StreamController<void> _onTransactionIngested =
      StreamController<void>.broadcast();
  static Stream<void> get onTransactionIngested =>
      _onTransactionIngested.stream;

  static void notifyTransactionIngested() {
    _onTransactionIngested.add(null);
  }

  static String extractBankCode(String bankName) {
    final clean = bankName.toLowerCase();
    for (final code in [
      'hdfc',
      'sbi',
      'icici',
      'axis',
      'kotak',
      'pnb',
      'bob',
      'yes',
      'citi',
      'hsbc',
      'paytm',
      'gpay',
    ]) {
      if (clean.contains(code)) return code;
    }
    return clean.split(' ').first;
  }

  static final _nlog = NotificationLogService.instance;

  /// Checks if the native Android NotificationListenerService is currently connected / bound by the system.
  static Future<bool> isServiceConnected() async {
    try {
      final bool? isConnected = await _methodeChannel.invokeMethod<bool>(
        'isServiceConnected',
      );
      return isConnected ?? false;
    } catch (e) {
      await _nlog.logError(
        'STATUS_CHECK',
        'Failed to check isServiceConnected: $e',
      );
      return false;
    }
  }

  /// Forces Android OS to reconnect/rebind the NotificationListenerService.
  static Future<bool> reconnectService() async {
    await _nlog.log('RECONNECT', 'Requesting native listener reconnection...');
    bool rebindSuccess = false;

    // 1. Try official Android N+ requestRebind
    try {
      final res = await _methodeChannel.invokeMethod<bool>(
        'forceRequestRebind',
      );
      if (res == true) {
        rebindSuccess = true;
        await _nlog.log('RECONNECT', 'forceRequestRebind succeeded.');
      }
    } catch (e) {
      await _nlog.log(
        'RECONNECT',
        'forceRequestRebind not supported or failed: $e',
      );
    }

    // 2. Try component toggle (DISABLED -> ENABLED)
    try {
      final res = await _methodeChannel.invokeMethod<bool>('reconnectService');
      if (res == true) {
        rebindSuccess = true;
        await _nlog.log(
          'RECONNECT',
          'reconnectService (component toggle) executed.',
        );
      }
    } catch (e) {
      await _nlog.logError('RECONNECT', 'reconnectService failed: $e');
    }

    // Check new status after brief delay
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final newConnected = await isServiceConnected();
    await _nlog.log(
      'RECONNECT',
      'Connection status after rebind attempt: isConnected=$newConnected',
    );

    return newConnected || rebindSuccess;
  }

  static Future<void> initialize({bool forceRequest = false}) async {
    if (_isInitialized) {
      await _nlog.log('INIT', 'Notification Service is already initialized.');
      return;
    }
    if (_isInitializing) {
      await _nlog.log('INIT', 'Initialization is already in progress.');
      return;
    }
    _isInitializing = true;

    await _nlog.log('INIT', 'Initializing Notification Service...');

    try {
      WidgetsFlutterBinding.ensureInitialized();
      DartPluginRegistrant.ensureInitialized();
    } catch (e) {
      await _nlog.logError('INIT', 'Error initializing bindings: $e');
    }

    // Check if the user has already given our app permission
    bool isGranted = false;
    try {
      isGranted = await NotificationListenerService.isPermissionGranted();
    } catch (e, stack) {
      await _nlog.logError(
        'PERMISSION',
        'Error checking notification permission: $e\n$stack',
      );
    }

    if (!isGranted && forceRequest) {
      await _nlog.log('PERMISSION', 'Permission not granted. Requesting...');
      try {
        // This will pop open the Android settings screen for the user
        isGranted = await NotificationListenerService.requestPermission();
      } catch (e, stack) {
        await _nlog.logError(
          'PERMISSION',
          'Error requesting notification permission: $e\n$stack',
        );
      }
    }

    if (isGranted) {
      // Check native listener connection state
      final isConnected = await isServiceConnected();
      await _nlog.log(
        'INIT',
        'Permission granted! Connection status: isConnected=$isConnected',
      );

      if (!isConnected) {
        await _nlog.log(
          'INIT',
          'Permission granted, but native listener is UNBOUND by Android. Triggering auto-rebind...',
        );
        await reconnectService();
      }

      // This stream runs continuously in the background
      try {
        _subscription = NotificationListenerService.notificationsStream.listen(
          (event) async {
            await _processNotification(event, source: 'live');
          },
          onError: (e, stackTrace) {
            _nlog.logError(
              'STREAM',
              'Error in notifications stream: $e\n$stackTrace',
            );
          },
        );

        final queuedNotifications = await _drainNativeQueue();
        await _nlog.log(
          'RECOVERY',
          'Draining ${queuedNotifications.length} queued notifications.',
        );
        for (final event in queuedNotifications) {
          await _processNotification(event, source: 'native-queue');
        }

        // The package's EventChannel only works while this Flutter process is
        // alive. Recover notifications that Android still has active when the
        // app starts so a process restart does not automatically lose them.
        final activeNotifications =
            await NotificationListenerService.getActiveNotifications();
        await _nlog.log(
          'RECOVERY',
          'Inspecting ${activeNotifications.length} active notifications.',
        );
        for (final event in activeNotifications) {
          await _processNotification(event, source: 'active-recovery');
        }

        _isInitialized = true;
      } catch (e, stackTrace) {
        await _nlog.logError(
          'SUBSCRIBE',
          'Failed to subscribe to notificationsStream: $e\n$stackTrace',
        );
      }
    } else {
      await _nlog.log('INIT', 'Notification permission denied by user.');
    }
    _isInitializing = false;
  }

  static Future<List<ServiceNotificationEvent>> _drainNativeQueue() async {
    try {
      final rows = await _queueChannel.invokeListMethod<dynamic>('drain');
      if (rows == null) return const [];
      return rows
          .whereType<Map<dynamic, dynamic>>()
          .map(
            (row) => ServiceNotificationEvent(
              id: row['id'] as int? ?? 0,
              title: row['title'] as String? ?? '',
              content: row['content'] as String? ?? '',
              packageName: row['packageName'] as String? ?? '',
              hasRemoved: row['hasRemoved'] as bool? ?? false,
              timestamp: row['postTime'] as int? ?? 0,
              canReply: false,
              haveExtraPicture: false,
              onGoing: false,
              appIcon: null,
              extrasPicture: null,
              largeIcon: null,
            ),
          )
          .toList();
    } on MissingPluginException {
      // Expected on non-Android platforms and in widget tests.
      return const [];
    } catch (error) {
      await _nlog.logError('RECOVERY', 'Failed to drain native queue: $error');
      return const [];
    }
  }

  static Future<void> _processNotification(
    ServiceNotificationEvent event, {
    required String source,
  }) async {
    try {
      await _nlog.logNotificationReceived(
        packageName: event.packageName,
        title: event.title,
        content: event.content,
        hasRemoved: event.hasRemoved,
      );

      if (event.hasRemoved) {
        await _nlog.logFilterDecision(
          packageName: event.packageName,
          passed: false,
          reason: '$source: notification removed',
        );
        return;
      }
      if (event.packageName == 'com.calvin.expense_tracker') {
        await _nlog.logFilterDecision(
          packageName: event.packageName,
          passed: false,
          reason: '$source: own app notification',
        );
        return;
      }

      final parsed = NotificationParser.parse(event.title, event.content);
      if (parsed == null) {
        await _nlog.logParseResult(
          success: false,
          rawInput: '${event.title} | ${event.content}',
        );
        return;
      }
      await _nlog.logParseResult(
        success: true,
        parsedSummary: '$source | $parsed',
      );

      final accounts = await AppDatabase.instance.getAllAccounts();
      if (accounts.isEmpty) {
        await _nlog.logError(
          'ACCOUNTS',
          'No accounts found. Cannot save parsed transaction.',
        );
        return;
      }

      final matchedAccount = _matchAccount(accounts, parsed);
      final eventTime = event.timestamp > 0
          ? DateTime.fromMillisecondsSinceEpoch(event.timestamp)
          : DateTime.now();
      final isDuplicate = await AppDatabase.instance.hasRecentDuplicate(
        amount: parsed.amount,
        type: parsed.type,
        accountId: matchedAccount.id!,
        merchant: parsed.merchant,
        referenceTime: eventTime,
        window: const Duration(minutes: 5),
      );
      await _nlog.logDuplicateCheck(
        isDuplicate: isDuplicate,
        details:
            '$source amount=${parsed.amount} type=${parsed.type} '
            'account=${matchedAccount.bankName} merchant=${parsed.merchant}',
      );
      if (isDuplicate) return;

      final id = await AppDatabase.instance.createTransaction(
        Transaction(
          amount: parsed.amount,
          type: parsed.type,
          timestamp: eventTime,
          merchant: parsed.merchant,
          category: parsed.category,
          accountId: matchedAccount.id!,
        ),
      );
      await _nlog.logDatabaseWrite(
        transactionId: id,
        accountName: matchedAccount.bankName,
      );
      _onTransactionIngested.add(null);
    } catch (e, stackTrace) {
      await _nlog.logError(
        'PROCESS',
        '$source notification failed: $e\n$stackTrace',
      );
    }
  }

  static Account _matchAccount(
    List<Account> accounts,
    ParsedNotification parsed,
  ) {
    final bankCode = extractBankCode(parsed.bankName);
    final cardEnding = parsed.cardEnding;
    Account? matched;

    if (cardEnding != null && cardEnding.isNotEmpty) {
      matched = accounts.cast<Account?>().firstWhere(
        (account) =>
            account!.bankName.toLowerCase().contains(bankCode) &&
            account.bankName.contains(cardEnding),
        orElse: () => null,
      );
      matched ??= accounts.cast<Account?>().firstWhere(
        (account) => account!.bankName.contains(cardEnding),
        orElse: () => null,
      );
    }
    if (parsed.bankName != 'Unknown Bank') {
      matched ??= accounts.cast<Account?>().firstWhere(
        (account) => account!.bankName.toLowerCase().contains(bankCode),
        orElse: () => null,
      );
    }
    return matched ?? accounts.first;
  }

  static void dispose() {
    try {
      _subscription?.cancel();
    } catch (e) {
      _nlog.logError(
        'DISPOSE',
        'Error cancelling notification subscription: $e',
      );
    }
    _subscription = null;
    _isInitialized = false;
    _isInitializing = false;
    _nlog.log('DISPOSE', 'Notification Service disposed.');
  }
}
