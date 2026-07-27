import 'package:expense_tracker/core/models/financial_enums.dart';
import 'package:expense_tracker/core/models/money.dart';
import 'package:expense_tracker/core/models/transaction.dart';
import 'package:expense_tracker/features/ingestion/notification_parsing_pipeline.dart';

export 'package:expense_tracker/features/ingestion/notification_parsing_pipeline.dart';

class ParsedNotification {
  const ParsedNotification({
    required this.amount,
    required this.type,
    required this.merchant,
    required this.category,
    required this.bankName,
    this.cardEnding,
  });

  final double amount;
  final TransactionType type;
  final String merchant;
  final String category;
  final String bankName;
  final String? cardEnding;
}

/// Temporary compatibility adapter. New ingestion consumes
/// [NotificationParsingPipeline] directly.
class NotificationParser {
  NotificationParser._();

  static final NotificationParsingPipeline pipeline =
      NotificationParsingPipeline();

  static ParsedNotification? parse(String title, String content) {
    final result = pipeline.parse(title, content);
    final amount = result.selectedAmount;
    if (amount == null ||
        result.decision == ParseDecision.ignored ||
        result.direction == FinancialDirection.unknown ||
        result.direction == FinancialDirection.none) {
      return null;
    }
    return ParsedNotification(
      amount: minorToMajor(amount.amountMinor),
      type: result.direction == FinancialDirection.credit
          ? TransactionType.credit
          : TransactionType.debit,
      merchant: result.merchant.raw ?? 'Unknown',
      category: categorizeMerchant(result.merchant.normalized ?? ''),
      bankName: _displayInstitution(result.institutionId),
      cardEnding: result.instrument.lastFour,
    );
  }

  static String? extractCardEndingDigits(String text) {
    return DefaultInstrumentExtractor()
        .extract(DefaultNotificationNormalizer().normalize('', text))
        .value
        .lastFour;
  }

  static String categorizeMerchant(String merchantName) {
    final lower = merchantName.toLowerCase().trim();
    if (_containsAny(lower, [
      'zomato',
      'swiggy',
      'starbucks',
      'mcdonald',
      'dominos',
      'pizza',
      'restaurant',
      'cafe',
      'bakery',
      'food',
    ])) {
      return 'Food & Dining';
    }
    if (_containsAny(lower, [
      'uber',
      'ola',
      'rapido',
      'irctc',
      'metro',
      'fuel',
      'petrol',
      'taxi',
      'flight',
      'toll',
      'fastag',
    ])) {
      return 'Travel & Transport';
    }
    if (_containsAny(lower, [
      'jio',
      'airtel',
      'vodafone',
      'netflix',
      'spotify',
      'electricity',
      'recharge',
      'insurance',
      'broadband',
      'utility',
      'dth',
    ])) {
      return 'Bills & Utilities';
    }
    if (_containsAny(lower, [
      'amazon',
      'flipkart',
      'myntra',
      'nykaa',
      'mall',
      'grocery',
      'blinkit',
      'instamart',
      'bigbasket',
      'store',
      'supermarket',
      'retail',
    ])) {
      return 'Shopping';
    }
    if (_containsAny(lower, [
      'rent',
      'landlord',
      'maintenance',
      'flat',
      'housing',
    ])) {
      return 'Rent';
    }
    if (_containsAny(lower, [
      'salary',
      'dividend',
      'interest',
      'cashback',
      'refund',
      'payout',
      'employer',
    ])) {
      return 'Salary';
    }
    return 'Others';
  }

  static bool _containsAny(String text, List<String> values) =>
      values.any(text.contains);

  static String _displayInstitution(String? code) => switch (code) {
    'hdfc' => 'HDFC Bank',
    'axis' => 'Axis Bank',
    'sbi' => 'SBI',
    'icici' => 'ICICI',
    'kotak' => 'KOTAK',
    null => 'Unknown Bank',
    _ => code.toUpperCase(),
  };
}
