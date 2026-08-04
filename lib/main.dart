import 'dart:async';

import 'package:expense_tracker/app_shell.dart';
import 'package:expense_tracker/core/database/app_database.dart';
import 'package:expense_tracker/core/security/app_lock_gate.dart';
import 'package:expense_tracker/core/services/notification_log_service.dart';
import 'package:expense_tracker/core/services/reminder_notification_service.dart';
import 'package:expense_tracker/core/theme/app_theme.dart';
import 'package:expense_tracker/features/ingestion/notification_service.dart';
import 'package:expense_tracker/features/onboarding/presentation/onboarding_screen.dart';
import 'package:flutter/material.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  AppTheme.configureOfflineFonts();
  ReminderNotificationService.instance.initialize();
  runApp(const ExpenseTrackerApp());
}

class ExpenseTrackerApp extends StatelessWidget {
  const ExpenseTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Expense Tracker',
      theme: AppTheme.lightTheme,
      home: const AppLockGate(child: _AppEntry()),
    );
  }
}

class _AppEntry extends StatefulWidget {
  const _AppEntry();

  @override
  State<_AppEntry> createState() => _AppEntryState();
}

class _AppEntryState extends State<_AppEntry> {
  late Future<Widget> _initialScreenFuture;

  @override
  void initState() {
    super.initState();
    _loadInitialScreen();
  }

  void _loadInitialScreen() {
    _initialScreenFuture = _resolveInitialScreen();
  }

  Future<Widget> _resolveInitialScreen() async {
    final database = AppDatabase.instance;
    final accounts = await database.getAllAccounts();
    await database.redactNonReviewRawNotificationPayloads();
    await NotificationLogService.instance.enforcePrivacyPolicy();
    // Do not let notification ingestion race encryption migration or schema
    // validation during cold start.
    unawaited(NotificationService.initialize(forceRequest: false));
    if (accounts.isNotEmpty) {
      return const AppShell();
    }
    return const OnboardingScreen();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Widget>(
      future: _initialScreenFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        if (snapshot.hasError) {
          return Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      size: 56,
                      color: AppTheme.errorRed,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Could not open database',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Your encrypted data has been preserved. Retry after '
                      'unlocking the device. If the problem continues, do not '
                      'clear app storage or reinstall the app.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppTheme.textMuted),
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton(
                      onPressed: () {
                        setState(() {
                          _loadInitialScreen();
                        });
                      },
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        return snapshot.data ?? const OnboardingScreen();
      },
    );
  }
}
