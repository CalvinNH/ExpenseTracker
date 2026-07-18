import 'package:flutter_test/flutter_test.dart';
import 'package:expense_tracker/features/ingestion/notification_parser.dart';
import 'package:expense_tracker/core/models/transaction.dart';

void main() {
  group('NotificationParser Tests', () {
    test('Debit test with UPI slash format and Rs.', () {
      final parsed = NotificationParser.parse(
        'Bank Alert',
        'Your a/c no. XXXX1234 is debited for Rs. 500.00 on 20-06-2026 by UPI/Starbucks/123.',
      );

      expect(parsed, isNotNull);
      expect(parsed!.amount, 500.00);
      expect(parsed.type, TransactionType.debit);
      expect(parsed.merchant, 'Starbucks');
      expect(parsed.category, 'Food & Dining');
      expect(parsed.bankName, 'Unknown Bank'); // No bank specified in text except a/c ending
    });

    test('Debit test with at prefix and SBI bank prefix', () {
      final parsed = NotificationParser.parse(
        'SBI Alert',
        'SBI A/c XXXXX123 is debited by Rs.1,250.50 on 22-06-26 at Zomato.',
      );

      expect(parsed, isNotNull);
      expect(parsed!.amount, 1250.50);
      expect(parsed.type, TransactionType.debit);
      expect(parsed.merchant, 'Zomato');
      expect(parsed.category, 'Food & Dining');
      expect(parsed.bankName, 'SBI');
    });

    test('Credit test with INR and info prefix', () {
      final parsed = NotificationParser.parse(
        'HDFC Bank txn',
        'INR 25,000.00 credited to A/c ...7890 by HDFC BANK info:Salary.',
      );

      expect(parsed, isNotNull);
      expect(parsed!.amount, 25000.00);
      expect(parsed.type, TransactionType.credit);
      expect(parsed.merchant, 'Salary');
      expect(parsed.category, 'Salary');
      expect(parsed.bankName, 'HDFC Bank');
    });

    test('Debit test with ₹ symbol, for prefix, and Axis Bank', () {
      final parsed = NotificationParser.parse(
        'Axis Bank Alert',
        '₹120.00 spent on Axis Bank A/c ...5678 for Netflix.',
      );

      expect(parsed, isNotNull);
      expect(parsed!.amount, 120.00);
      expect(parsed.type, TransactionType.debit);
      expect(parsed.merchant, 'Netflix');
      expect(parsed.category, 'Bills & Utilities');
      expect(parsed.bankName, 'Axis Bank');
    });

    test('Debit test with Card ending, to prefix, and HDFC bank', () {
      final parsed = NotificationParser.parse(
        'Transaction Alert',
        'Dear Customer, txn of Rs. 4,500.00 on HDFC Bank Card ending 1234 to Amazon.',
      );

      expect(parsed, isNotNull);
      expect(parsed!.amount, 4500.00);
      expect(parsed.type, TransactionType.debit);
      expect(parsed.merchant, 'Amazon');
      expect(parsed.category, 'Shopping');
      expect(parsed.bankName, 'HDFC Bank');
      expect(parsed.cardEnding, '1234');
    });

    test('Card ending digits extraction regex tests', () {
      expect(NotificationParser.extractCardEndingDigits('Card ending 6005'), '6005');
      expect(NotificationParser.extractCardEndingDigits('Your card XXX1234 spent Rs.100'), '1234');
      expect(NotificationParser.extractCardEndingDigits('Account XXX672345 debited'), '2345');
      expect(NotificationParser.extractCardEndingDigits('A/c ...5678 credited'), '5678');
      expect(NotificationParser.extractCardEndingDigits('No card digits here'), isNull);
    });

    test('Non-transaction notification should return null', () {
      final parsed = NotificationParser.parse(
        'Welcome',
        'Thank you for downloading Expense Tracker app!',
      );

      expect(parsed, isNull);
    });

    test('Known merchant fallback without prefix', () {
      final parsed = NotificationParser.parse(
        'Notification',
        'Paid ₹400 on Ola Cabs app with Paytm.',
      );

      expect(parsed, isNotNull);
      expect(parsed!.amount, 400.00);
      expect(parsed.merchant, 'Ola');
      expect(parsed.category, 'Travel & Transport');
    });

    test('Heuristics category matches mixed casing, trailing spaces and unmatched fallback', () {
      // 1. Food & Dining (mixed casing, spaces)
      expect(NotificationParser.categorizeMerchant('   ZoMaTo  '), 'Food & Dining');
      // 2. Travel & Transport (mixed casing, spaces)
      expect(NotificationParser.categorizeMerchant('  uBeR '), 'Travel & Transport');
      // 3. Bills & Utilities (mixed casing, spaces)
      expect(NotificationParser.categorizeMerchant(' nEtFlIx  '), 'Bills & Utilities');
      // 4. Shopping (mixed casing, spaces)
      expect(NotificationParser.categorizeMerchant('  aMaZoN   '), 'Shopping');
      // 5. Rent (mixed casing, spaces)
      expect(NotificationParser.categorizeMerchant(' rEnT '), 'Rent');
      // 6. Salary (mixed casing, spaces)
      expect(NotificationParser.categorizeMerchant(' SaLaRy '), 'Salary');
      // 7. Others (payment gateway fallback)
      expect(NotificationParser.categorizeMerchant(' Paytm '), 'Others');
      expect(NotificationParser.categorizeMerchant(' Gpay '), 'Others');
      // 8. Others (completely unknown merchant)
      expect(NotificationParser.categorizeMerchant('SomeRandomMerchantName'), 'Others');
      expect(NotificationParser.categorizeMerchant(''), 'Others');
    });
  });
}
