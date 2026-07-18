import 'package:expense_tracker/app_shell.dart';
import 'package:expense_tracker/core/database/app_database.dart';
import 'package:expense_tracker/core/theme/app_theme.dart';
import 'package:expense_tracker/features/ingestion/notification_service.dart';
import 'package:expense_tracker/features/onboarding/presentation/onboarding_screen.dart';
import 'package:flutter/material.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  NotificationService.initialize(forceRequest: false);
  runApp(const ExpenseTrackerApp());
}

class ExpenseTrackerApp extends StatelessWidget {
  const ExpenseTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Expense Tracker',
      theme: AppTheme.lightTheme,
      home: const _AppEntry(),
    );
  }
}

class _AppEntry extends StatelessWidget {
  const _AppEntry();

  Future<Widget> _resolveInitialScreen() async {
    final accounts = await AppDatabase.instance.getAllAccounts();
    if (accounts.isNotEmpty) {
      return const AppShell();
    }
    return const OnboardingScreen();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Widget>(
      future: _resolveInitialScreen(),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        return snapshot.data ?? const OnboardingScreen();
      },
    );
  }
}
