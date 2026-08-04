import 'dart:io';

import 'package:expense_tracker/core/security/device_authenticator.dart';
import 'package:expense_tracker/core/theme/app_theme.dart';
import 'package:flutter/material.dart';

/// Gates the app behind device authentication (biometric or device
/// PIN/pattern/password). Re-locks whenever the app is backgrounded.
class AppLockGate extends StatefulWidget {
  const AppLockGate({
    super.key,
    required this.child,
    this.authenticator,
    this.bypassAuthenticationInTests = true,
  });

  final Widget child;
  final DeviceAuthenticator? authenticator;

  /// Keeps ordinary widget tests independent of the platform auth prompt.
  ///
  /// Authentication-specific tests disable this and inject an authenticator.
  final bool bypassAuthenticationInTests;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  late final DeviceAuthenticator _authenticator;
  bool _unlocked = false;
  bool _authInProgress = false;

  @override
  void initState() {
    super.initState();
    _authenticator = widget.authenticator ?? LocalDeviceAuthenticator();
    if (_shouldBypassAuthentication) {
      _unlocked = true;
    }
    WidgetsBinding.instance.addObserver(this);
    if (!_shouldBypassAuthentication) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _authenticate());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  bool get _isTestEnvironment =>
      WidgetsBinding.instance.runtimeType.toString().contains('Test') ||
      Platform.environment.containsKey('FLUTTER_TEST');

  bool get _shouldBypassAuthentication =>
      widget.bypassAuthenticationInTests && _isTestEnvironment;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_shouldBypassAuthentication) return;

    // Re-lock on backgrounding, but not when the pause is caused by
    // the system auth prompt itself (_authInProgress guard).
    final isBackgrounded =
        state == AppLifecycleState.hidden || state == AppLifecycleState.paused;
    if (isBackgrounded && !_authInProgress && _unlocked) {
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
      final supported = await _authenticator.isDeviceSupported();
      if (!mounted) return;
      if (!supported) {
        // Avoid permanently locking the user out on platforms that do not
        // provide a supported device-authentication mechanism.
        setState(() => _unlocked = true);
        return;
      }
      final ok = await _authenticator.authenticate();
      if (mounted && ok) setState(() => _unlocked = true);
    } on Exception {
      // Prompt unavailable or cancelled: stay locked. The user can
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
