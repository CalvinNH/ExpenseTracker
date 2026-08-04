import 'package:expense_tracker/core/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Inter typography loads entirely from bundled assets', (
    WidgetTester tester,
  ) async {
    AppTheme.configureOfflineFonts();

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: const Scaffold(body: Text('Offline expense tracking')),
      ),
    );

    await tester.pump();

    final context = tester.element(find.text('Offline expense tracking'));
    final theme = Theme.of(context);
    expect(theme.textTheme.bodyMedium?.fontFamily, 'Inter');
    expect(theme.appBarTheme.titleTextStyle?.fontFamily, 'Inter');
    expect(tester.takeException(), isNull);

    final license = await rootBundle.loadString('assets/fonts/inter/OFL.txt');
    expect(license, contains('SIL OPEN FONT LICENSE Version 1.1'));
  });
}
