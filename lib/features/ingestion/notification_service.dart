import 'dart:async';
import 'dart:ui';
import 'package:collection/collection.dart';
import 'package:expense_tracker/core/database/app_database.dart';
import 'package:expense_tracker/core/models/account.dart';
import 'package:expense_tracker/core/models/transaction.dart';
import 'package:expense_tracker/features/ingestion/notification_parser.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:notification_listener_service/notification_listener_service.dart';

class NotificationService {
  static StreamSubscription? _subscription;
  static bool _isInitialized = false;
  static const MethodChannel _systemChannel =
      MethodChannel('com.calvin.expense_tracker/system');
  static String? _defaultSmsPackage;

  // Static broadcast stream controller to notify UI of background transaction ingestions
  static final StreamController<void> _onTransactionIngested = StreamController<void>.broadcast();
  static Stream<void> get onTransactionIngested => _onTransactionIngested.stream;

  static void notifyTransactionIngested() {
    _onTransactionIngested.add(null);
  }

  static String extractBankCode(String bankName) {
    final clean = bankName.toLowerCase();
    for (final code in [
      'hdfc', 'sbi', 'icici', 'axis', 'kotak', 'pnb', 'bob', 'yes', 'citi', 'hsbc', 'paytm', 'gpay'
    ]) {
      if (clean.contains(code)) return code;
    }
    return clean.split(' ').first;
  }

  static void _log(String message) {
    // Disabled for production audit
  }

  static Future<void> initialize({bool forceRequest = false}) async {
    if (_isInitialized) {
      _log("Notification Service is already initialized.");
      return;
    }

    _log("Initializing Notification Service...");

    try {
      WidgetsFlutterBinding.ensureInitialized();
      DartPluginRegistrant.ensureInitialized();
    } catch (e) {
      _log("Error initializing bindings: $e");
    }

    // Check if the user has already given our app permission
    bool isGranted = false;
    try {
      isGranted = await NotificationListenerService.isPermissionGranted();
    } catch (e, stack) {
      _log("Error checking notification permission: $e\n$stack");
    }

    if (!isGranted && forceRequest) {
      _log("Permission not granted. Requesting...");
      try {
        // This will pop open the Android settings screen for the user
        isGranted = await NotificationListenerService.requestPermission();
      } catch (e, stack) {
        _log("Error requesting notification permission: $e\n$stack");
      }
    }

    if (isGranted) {
      _log("Permission granted! Listening for notifications...");
      _isInitialized = true;

      // Resolve the default SMS app once; only its notifications are ingested.
      try {
        _defaultSmsPackage =
            await _systemChannel.invokeMethod<String>('getDefaultSmsPackage');
        _log("Default SMS package: $_defaultSmsPackage");
      } catch (e) {
        _defaultSmsPackage = null;
        _log("Failed to resolve default SMS package: $e");
      }

      // This stream runs continuously in the background
      try {
        _subscription = NotificationListenerService.notificationsStream.listen((event) async {
          try {
            // Initialize Flutter platform channel messenger inside background Isolate context
            WidgetsFlutterBinding.ensureInitialized();
            DartPluginRegistrant.ensureInitialized();

            _log("--- NEW NOTIFICATION ---");
            _log("App: ${event.packageName}");
            _log("Title: ${event.title}");
            _log("Content: ${event.content}");
            _log("------------------------");

            if (event.hasRemoved == true) return;

            // Resolve default SMS package lazily inside background isolate context if needed
            if (_defaultSmsPackage == null) {
              try {
                _defaultSmsPackage = await _systemChannel
                    .invokeMethod<String>('getDefaultSmsPackage');
              } catch (_) {}
            }

            // Only ingest notifications from the default SMS app. Fail closed:
            // if the package could not be resolved, ingest nothing.
            if (_defaultSmsPackage != null &&
                event.packageName != _defaultSmsPackage) {
              _log("Ignored notification from ${event.packageName} "
                  "(not the default SMS app: $_defaultSmsPackage).");
              return;
            }

            final parsed = NotificationParser.parse(event.title ?? '', event.content ?? '');
            if (parsed == null) {
              _log("Notification is not a valid transaction or could not be parsed.");
              return;
            }

            _log("Successfully parsed transaction notification: $parsed");

            final accounts = await AppDatabase.instance.getAllAccounts();
            if (accounts.isEmpty) {
              _log("No accounts found in database. Cannot save transaction.");
              return;
            }

            // Match account by bank code and card ending digits
            final bankCode = extractBankCode(parsed.bankName);
            final cardEnding = parsed.cardEnding;

            Account? matchedAccount;
            if (cardEnding != null && cardEnding.isNotEmpty) {
              // Priority 1: Match both bank code and card ending
              matchedAccount = accounts.firstWhereOrNull(
                (acc) =>
                    acc.bankName.toLowerCase().contains(bankCode) &&
                    acc.bankName.contains(cardEnding),
              );
              // Priority 2: Match card ending alone
              matchedAccount ??= accounts.firstWhereOrNull(
                (acc) => acc.bankName.contains(cardEnding),
              );
            }

            // Priority 3: Match bank code alone (e.g., 'hdfc', 'sbi', 'icici')
            matchedAccount ??= accounts.firstWhereOrNull(
              (acc) => acc.bankName.toLowerCase().contains(bankCode),
            );

            // Priority 4: Fallback to first account
            matchedAccount ??= accounts.first;

            // Suppress duplicates: the same SMS can be re-delivered when the SMS
            // app updates its conversation notification.
            final isDuplicate = await AppDatabase.instance.hasRecentDuplicate(
              amount: parsed.amount,
              type: parsed.type,
              accountId: matchedAccount.id!,
              merchant: parsed.merchant,
            );
            if (isDuplicate) {
              _log("Skipped duplicate transaction: ${parsed.amount} "
                  "${parsed.type} on account ${matchedAccount.bankName}");
              return;
            }

            final transaction = Transaction(
              amount: parsed.amount,
              type: parsed.type,
              timestamp: DateTime.now(),
              merchant: parsed.merchant,
              category: parsed.category,
              accountId: matchedAccount.id!,
            );

            final id = await AppDatabase.instance.createTransaction(transaction);
            _log("Saved transaction to database with ID: $id on account: ${matchedAccount.bankName}");
            
            // Signal any active UI listeners to reload their data
            _onTransactionIngested.add(null);
          } catch (e, stackTrace) {
            // Robust catch-all to prevent unhandled PlatformException / missing channel crashes in background thread
            _log("Error inside background notification listener isolate: $e\n$stackTrace");
          }
        }, onError: (e, stackTrace) {
          _log("Error in notifications stream: $e\n$stackTrace");
        });
      } catch (e, stackTrace) {
        _log("Failed to subscribe to notificationsStream: $e\n$stackTrace");
      }
    } else {
      _log("Notification permission denied by user.");
    }
  }

  static void dispose() {
    try {
      _subscription?.cancel();
    } catch (e) {
      _log("Error cancelling notification subscription: $e");
    }
    _subscription = null;
    _isInitialized = false;
    _log("Notification Service disposed.");
  }
}
