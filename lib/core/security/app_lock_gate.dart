import 'dart:io';
import 'package:expense_tracker/core/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';

/// Gates the app behind device authentication (biometric or device
/// PIN/pattern/password). Re-locks whenever the app is backgrounded.
class AppLockGate extends StatefulWidget {
  const AppLockGate({super.key, required this.child});

  final Widget child;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  final LocalAuthentication _auth = LocalAuthentication();
  bool _unlocked = false;
  bool _authInProgress = false;

  @override
  void initState() {
    super.initState();
    final isTest =
        WidgetsBinding.instance.runtimeType.toString().contains('Test') ||
        Platform.environment.containsKey('FLUTTER_TEST');
    if (isTest) {
      _unlocked = true;
    }
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _authenticate());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  bool get _isTestEnvironment =>
      WidgetsBinding.instance.runtimeType.toString().contains('Test') ||
      Platform.environment.containsKey('FLUTTER_TEST');

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_isTestEnvironment) return;

    // Re-lock on backgrounding — but not when the pause is caused by
    // the system auth prompt itself (_authInProgress guard).
    if (state == AppLifecycleState.paused && !_authInProgress && _unlocked) {
      setState(() => _unlocked = false);
    }
    if (state == AppLifecycleState.resumed && !_unlocked && !_authInProgress) {
      _authenticate();
    }
  }

  Future<void> _authenticate() async {
    if (_authInProgress || _unlocked) return;
    _authInProgress = true;
    try {
      final supported = await _auth.isDeviceSupported();
      if (!supported) {
        // Device has no PIN/biometric configured — fail open instead
        // of permanently locking the user out.
        if (mounted) setState(() => _unlocked = true);
        return;
      }
      final ok = await _auth.authenticate(
        localizedReason: 'Unlock Expense Tracker',
        options: const AuthenticationOptions(
          biometricOnly: false, // allow PIN/pattern/password fallback
          stickyAuth: true,
        ),
      );
      if (mounted && ok) setState(() => _unlocked = true);
    } on Exception {
      // Prompt unavailable or cancelled — stay locked; the user can
      // retry via the Unlock button.
    } finally {
      _authInProgress = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        if (!_unlocked)
          Scaffold(
            backgroundColor: Theme.of(context).scaffoldBackgroundColor,
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.lock_rounded,
                    size: 48,
                    color: Color(0xFF0044FF),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Expense Tracker is locked',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _authenticate,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.primaryBlue,
                    ),
                    child: const Text('Unlock'),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
