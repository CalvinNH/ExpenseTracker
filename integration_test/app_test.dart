import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:integration_test/integration_test.dart';

import 'package:expense_tracker/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('app launches successfully', (tester) async {
    app.main();
    await tester.pumpAndSettle();

    expect(find.byType(app.ExpenseTrackerApp), findsOneWidget);
    expect(
      find.text('Could not open database'),
      findsNothing,
      reason: 'SQLCipher must open and validate during cold start.',
    );
  });

  testWidgets('native time-zone bridge returns a scheduling identifier', (
    tester,
  ) async {
    const channel = MethodChannel('expense_tracker/device_timezone');

    final identifier = await channel.invokeMethod<String>('getLocalTimeZone');

    expect(identifier, isNotNull);
    expect(identifier, isNotEmpty);
  });
}
