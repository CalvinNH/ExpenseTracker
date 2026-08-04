import 'package:expense_tracker/core/security/app_lock_gate.dart';
import 'package:expense_tracker/core/security/device_authenticator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('unlocks after successful device authentication', (tester) async {
    final authenticator = _FakeAuthenticator(authenticationResults: [true]);

    await _pumpGate(tester, authenticator);

    expect(find.text('Expense Tracker is locked'), findsNothing);
    expect(authenticator.supportChecks, 1);
    expect(authenticator.authenticationAttempts, 1);
  });

  testWidgets('stays locked after cancellation and lets the user retry', (
    tester,
  ) async {
    final authenticator = _FakeAuthenticator(
      authenticationResults: [false, true],
    );

    await _pumpGate(tester, authenticator);

    expect(find.text('Expense Tracker is locked'), findsOneWidget);
    expect(authenticator.authenticationAttempts, 1);

    await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
    await tester.pumpAndSettle();

    expect(find.text('Expense Tracker is locked'), findsNothing);
    expect(authenticator.authenticationAttempts, 2);
  });

  testWidgets('does not bypass the lock when authentication throws', (
    tester,
  ) async {
    final authenticator = _FakeAuthenticator(error: Exception('unavailable'));

    await _pumpGate(tester, authenticator);

    expect(find.text('Expense Tracker is locked'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Unlock'), findsOneWidget);
  });

  testWidgets('does not permanently lock unsupported devices', (tester) async {
    final authenticator = _FakeAuthenticator(isSupported: false);

    await _pumpGate(tester, authenticator);

    expect(find.text('Expense Tracker is locked'), findsNothing);
    expect(authenticator.supportChecks, 1);
    expect(authenticator.authenticationAttempts, 0);
  });

  testWidgets('re-locks in the background and requires auth after resume', (
    tester,
  ) async {
    final authenticator = _FakeAuthenticator(
      authenticationResults: [true, false, true],
    );

    await _pumpGate(tester, authenticator);
    expect(find.text('Expense Tracker is locked'), findsNothing);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(find.text('Expense Tracker is locked'), findsOneWidget);
    expect(authenticator.authenticationAttempts, 2);

    await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
    await tester.pumpAndSettle();

    expect(find.text('Expense Tracker is locked'), findsNothing);
    expect(authenticator.authenticationAttempts, 3);
  });
}

Future<void> _pumpGate(
  WidgetTester tester,
  DeviceAuthenticator authenticator,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: AppLockGate(
        authenticator: authenticator,
        bypassAuthenticationInTests: false,
        child: const Scaffold(body: Text('Private content')),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

final class _FakeAuthenticator implements DeviceAuthenticator {
  _FakeAuthenticator({
    this.isSupported = true,
    this.authenticationResults = const [],
    this.error,
  });

  final bool isSupported;
  final List<bool> authenticationResults;
  final Exception? error;
  int supportChecks = 0;
  int authenticationAttempts = 0;

  @override
  Future<bool> isDeviceSupported() async {
    supportChecks += 1;
    return isSupported;
  }

  @override
  Future<bool> authenticate() async {
    authenticationAttempts += 1;
    if (error case final error?) throw error;
    return authenticationResults[authenticationAttempts - 1];
  }
}
