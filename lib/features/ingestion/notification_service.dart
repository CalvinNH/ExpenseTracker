import 'dart:async';
import 'dart:ui';
import 'package:expense_tracker/core/database/app_database.dart';
import 'package:expense_tracker/core/models/transaction.dart';
import 'package:expense_tracker/features/ingestion/notification_parser.dart';
import 'package:flutter/widgets.dart';
import 'package:notification_listener_service/notification_listener_service.dart';

class NotificationService {
  static StreamSubscription? _subscription;
  static bool _isInitialized = false;

  // Static broadcast stream controller to notify UI of background transaction ingestions
  static final StreamController<void> _onTransactionIngested = StreamController<void>.broadcast();
  static Stream<void> get onTransactionIngested => _onTransactionIngested.stream;

  static void notifyTransactionIngested() {
    _onTransactionIngested.add(null);
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

            final parsed = NotificationParser.parse(event.title, event.content);
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

            // Match account by bankName / cardEnding
            final matchedAccount = accounts.firstWhere(
              (acc) {
                if (parsed.cardEnding != null && acc.bankName.contains(parsed.cardEnding!)) {
                  return true;
                }
                return acc.bankName.toLowerCase().contains(parsed.bankName.toLowerCase()) ||
                       parsed.bankName.toLowerCase().contains(acc.bankName.toLowerCase());
              },
              orElse: () => accounts.first,
            );

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
