import 'package:expense_tracker/core/models/financial_enums.dart';
import 'package:expense_tracker/core/models/money.dart';
import 'package:expense_tracker/core/models/parsed_financial_event.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'money converts major values to integer minor units deterministically',
    () {
      expect(majorToMinor(12.34), 1234);
      expect(majorToMinor(12.345), 1235);
      expect(majorToMinor(-0.01), -1);
      expect(minorToMajor(1234), 12.34);
      expect(() => majorToMinor(double.infinity), throwsArgumentError);
    },
  );

  test('domain enums serialize and deserialize by stable names', () {
    for (final value in FinancialDirection.values) {
      expect(FinancialDirection.fromStorage(value.storageValue), same(value));
    }
    for (final value in FinancialEventType.values) {
      expect(FinancialEventType.fromStorage(value.storageValue), same(value));
    }
    for (final value in FinancialEventStatus.values) {
      expect(FinancialEventStatus.fromStorage(value.storageValue), same(value));
    }
    for (final value in ParseDecision.values) {
      expect(ParseDecision.fromStorage(value.storageValue), same(value));
    }
    for (final value in AccountType.values) {
      expect(AccountType.fromStorage(value.storageValue), same(value));
    }

    expect(
      FinancialDirection.fromStorage('future_value'),
      FinancialDirection.unknown,
    );
    expect(
      FinancialEventType.fromStorage('future_value'),
      FinancialEventType.unknown,
    );
    expect(
      FinancialEventStatus.fromStorage('future_value'),
      FinancialEventStatus.unknown,
    );
    expect(ParseDecision.fromStorage('future_value'), ParseDecision.retainOnly);
    expect(AccountType.fromStorage('future_value'), AccountType.unknown);
  });

  test('parsed financial event preserves serialized field confidence', () {
    final occurredAt = DateTime.utc(2026, 7, 25, 10, 30);
    final event = ParsedFinancialEvent(
      id: 3,
      rawNotificationEventId: 2,
      eventType: FinancialEventType.purchase,
      status: FinancialEventStatus.completed,
      direction: FinancialDirection.debit,
      amountMinor: 4999,
      currencyCode: 'INR',
      merchantRaw: 'TEST STORE',
      merchantNormalized: 'Test Store',
      institutionId: 'hdfc',
      instrumentLastFour: '1234',
      referenceNumber: 'ABC123',
      transactionOccurredAt: occurredAt,
      overallConfidence: 0.93,
      fieldConfidence: const {'amount': 0.99, 'merchant': 0.8},
      parseDecision: ParseDecision.autoPost,
    );

    final restored = ParsedFinancialEvent.fromMap(event.toMap());
    expect(restored.eventType, FinancialEventType.purchase);
    expect(restored.status, FinancialEventStatus.completed);
    expect(restored.direction, FinancialDirection.debit);
    expect(restored.amountMinor, 4999);
    expect(restored.transactionOccurredAt, occurredAt);
    expect(restored.fieldConfidence, {'amount': 0.99, 'merchant': 0.8});
    expect(restored.parseDecision, ParseDecision.autoPost);
  });
}
