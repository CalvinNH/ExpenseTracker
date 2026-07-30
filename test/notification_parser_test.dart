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
      expect(
        parsed.bankName,
        'Unknown Bank',
      ); // No bank specified in text except a/c ending
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
      expect(parsed.bankName, 'State Bank of India');
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

    test('Debit test with HDFC Bank A/C single asterisk account ending', () {
      final parsed = NotificationParser.parse(
        'HDFC Bank Alert',
        'Sent Rs.1.00 from HDFC Bank A/C *2962 to John Doe.',
      );

      expect(parsed, isNotNull);
      expect(parsed!.amount, 1.00);
      expect(parsed.type, TransactionType.debit);
      expect(parsed.bankName, 'HDFC Bank');
      expect(parsed.cardEnding, '2962');
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

    test('Ambiguous txn wording does not default to debit', () {
      final parsed = NotificationParser.parse(
        'Transaction Alert',
        'Dear Customer, txn of Rs. 4,500.00 on HDFC Bank Card ending 1234 to Amazon.',
      );

      expect(parsed, isNull);
    });

    test('Card ending digits extraction regex tests', () {
      expect(
        NotificationParser.extractCardEndingDigits('Card ending 6005'),
        '6005',
      );
      expect(
        NotificationParser.extractCardEndingDigits(
          'Your card XXX1234 spent Rs.100',
        ),
        '1234',
      );
      expect(
        NotificationParser.extractCardEndingDigits('Account XXX672345 debited'),
        '2345',
      );
      expect(
        NotificationParser.extractCardEndingDigits('A/c ...5678 credited'),
        '5678',
      );
      expect(
        NotificationParser.extractCardEndingDigits('No card digits here'),
        isNull,
      );
    });

    test('Non-transaction notification should return null', () {
      final parsed = NotificationParser.parse(
        'Welcome',
        'Thank you for downloading Expense Tracker app!',
      );

      expect(parsed, isNull);
    });

    test('OTP notification containing an amount is ignored', () {
      final parsed = NotificationParser.parse(
        'ICICI Bank OTP',
        'OTP 123456 is for txn of INR 4,999.00 at AMAZON. Do not share it.',
      );

      expect(parsed, isNull);
    });

    test('Balance summary containing an amount is ignored', () {
      final parsed = NotificationParser.parse(
        'SBI Balance',
        'Available balance in your account is INR 18,245.20.',
      );

      expect(parsed, isNull);
    });

    test('Parses multi-word merchant and masked account suffix', () {
      final parsed = NotificationParser.parse(
        'HDFC Bank',
        'Rs 1,249.50 debited from A/c XX672345 at Reliance Fresh Market '
            'on 24-07-2026. Avl bal Rs 8,000.00',
      );

      expect(parsed, isNotNull);
      expect(parsed!.amount, 1249.50);
      expect(parsed.type, TransactionType.debit);
      expect(parsed.merchant, 'Reliance Fresh Market');
      expect(parsed.cardEnding, '2345');
    });

    test('Parses refund as credit even when original debit is mentioned', () {
      final parsed = NotificationParser.parse(
        'Axis Bank',
        '₹750.00 refunded to Axis Bank card XX9911 for debit transaction '
            'at Myntra.',
      );

      expect(parsed, isNotNull);
      expect(parsed!.type, TransactionType.credit);
      expect(parsed.cardEnding, '9911');
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

    test('parse() returns null when the amount overflows to infinity', () {
      final content = 'Rs. ${'9' * 400} debited from HDFC a/c xx1234';
      final parsed = NotificationParser.parse('Transaction Alert', content);
      expect(parsed, isNull);
    });

    test('parse() returns null when the amount exceeds the cap', () {
      final parsed = NotificationParser.parse(
        'Transaction Alert',
        'Rs. 99,999,999 debited from HDFC a/c xx1234',
      );
      expect(parsed, isNull);
    });

    test(
      'Heuristics category matches mixed casing, trailing spaces and unmatched fallback',
      () {
        // 1. Food & Dining (mixed casing, spaces)
        expect(
          NotificationParser.categorizeMerchant('   ZoMaTo  '),
          'Food & Dining',
        );
        // 2. Travel & Transport (mixed casing, spaces)
        expect(
          NotificationParser.categorizeMerchant('  uBeR '),
          'Travel & Transport',
        );
        // 3. Bills & Utilities (mixed casing, spaces)
        expect(
          NotificationParser.categorizeMerchant(' nEtFlIx  '),
          'Bills & Utilities',
        );
        // 4. Shopping (mixed casing, spaces)
        expect(
          NotificationParser.categorizeMerchant('  aMaZoN   '),
          'Shopping',
        );
        // 5. Rent (mixed casing, spaces)
        expect(NotificationParser.categorizeMerchant(' rEnT '), 'Rent');
        // 6. Salary (mixed casing, spaces)
        expect(NotificationParser.categorizeMerchant(' SaLaRy '), 'Salary');
        // 7. Others (payment gateway fallback)
        expect(NotificationParser.categorizeMerchant(' Paytm '), 'Others');
        expect(NotificationParser.categorizeMerchant(' Gpay '), 'Others');
        // 8. Others (completely unknown merchant)
        expect(
          NotificationParser.categorizeMerchant('SomeRandomMerchantName'),
          'Others',
        );
        expect(NotificationParser.categorizeMerchant(''), 'Others');
      },
    );
  });
}
