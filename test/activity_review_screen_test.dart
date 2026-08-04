import 'package:expense_tracker/core/database/app_database.dart';
import 'package:expense_tracker/core/models/financial_enums.dart';
import 'package:expense_tracker/core/models/parsed_financial_event.dart';
import 'package:expense_tracker/core/models/raw_notification_event.dart';
import 'package:expense_tracker/features/activity/presentation/activity_screen.dart';
import 'package:expense_tracker/features/ingestion/notification_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    AppDatabase.databaseName = inMemoryDatabasePath;
  });

  setUp(() => AppDatabase.instance.close());
  tearDown(() => AppDatabase.instance.close());

  Future<void> waitForDatabase(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();
  }

  testWidgets(
    'review inbox refreshes, opens missing-amount item, and dismisses it',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: ActivityScreen()));
      await tester.pump();
      await waitForDatabase(tester);
      expect(find.text('Nothing to review!'), findsOneWidget);

      await tester.runAsync(() async {
        final observedAt = DateTime(2026, 7, 30, 10);
        final rawId = await AppDatabase.instance.createRawNotificationEvent(
          RawNotificationEvent(
            packageName: 'com.google.android.apps.messaging',
            notificationId: 801,
            content: 'Your account was debited at Cafe.',
            postedAt: observedAt,
            ingestedAt: observedAt,
            payloadHash: 'activity-review-widget',
            parserVersion: 1,
            processingState: RawNotificationProcessingState.failed,
          ),
        );
        await AppDatabase.instance.createParsedFinancialEvent(
          ParsedFinancialEvent(
            rawNotificationEventId: rawId,
            eventType: FinancialEventType.purchase,
            status: FinancialEventStatus.completed,
            direction: FinancialDirection.debit,
            merchantRaw: 'Cafe',
            merchantNormalized: 'cafe',
            transactionOccurredAt: observedAt,
            overallConfidence: .7,
            fieldConfidence: const {'transactionPhrase': .9},
            parseDecision: ParseDecision.retainOnly,
            failureCode: 'transaction_amount_missing',
          ),
        );
      });
      NotificationService.notifyReviewInboxChanged();
      await tester.pump();
      await waitForDatabase(tester);

      expect(find.text('Amount needs review'), findsOneWidget);
      expect(find.text('Cafe'), findsOneWidget);

      await tester.tap(find.text('Cafe'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Review transaction'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const Key('transaction-sheet-close')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      final review =
          (await AppDatabase.instance.getTransactionsForReview()).single;
      await tester.tap(
        find.byKey(Key('dismiss-review-${review.parsedEvent.id}')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Dismiss transaction?'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Dismiss'));
      await tester.pump();
      await waitForDatabase(tester);

      expect(find.text('Nothing to review!'), findsOneWidget);
      expect(await AppDatabase.instance.getTransactionsForReview(), isEmpty);
      await tester.pump(const Duration(seconds: 3));
      expect(tester.takeException(), isNull);
    },
  );
}
