import 'package:expense_tracker/core/models/transaction.dart';

class ParsedNotification {
  final double amount;
  final TransactionType type;
  final String merchant;
  final String category;
  final String bankName;
  final String? cardEnding;

  const ParsedNotification({
    required this.amount,
    required this.type,
    required this.merchant,
    required this.category,
    required this.bankName,
    this.cardEnding,
  });

  @override
  String toString() {
    return 'ParsedNotification(amount: $amount, type: $type, merchant: $merchant, category: $category, bankName: $bankName, cardEnding: $cardEnding)';
  }
}

class NotificationParser {
  NotificationParser._();

  static ParsedNotification? parse(String title, String content) {
    final text = '$title $content';

    // 1. Parse Amount
    // Regex matches Rs. 500, Rs 500, INR 500, ₹ 500, supports commas and decimals
    final amountRegex = RegExp(
      r'(?:Rs\.?|INR|₹)\s*([0-9,]+(?:\.[0-9]+)?)',
      caseSensitive: false,
    );
    final amountMatch = amountRegex.firstMatch(text);
    if (amountMatch == null) {
      return null; // A valid transaction notification must have an amount
    }

    final amountStr = amountMatch.group(1)!.replaceAll(',', '');
    final amount = double.tryParse(amountStr);
    if (amount == null || amount <= 0) {
      return null;
    }

    // 2. Parse Transaction Type
    TransactionType type = TransactionType.debit; // Default fallback
    final creditKeywords = RegExp(r'\b(credited|received|deposit|added|refunded)\b', caseSensitive: false);
    final debitKeywords = RegExp(r'\b(debited|spent|withdraw|sent|paid|transfer|spent|txn)\b', caseSensitive: false);

    if (creditKeywords.hasMatch(text)) {
      type = TransactionType.credit;
    } else if (debitKeywords.hasMatch(text)) {
      type = TransactionType.debit;
    }

    // 3. Parse Bank Name
    String bankName = 'Unknown Bank';
    final bankRegex = RegExp(
      r'\b(HDFC|SBI|ICICI|AXIS|KOTAK|PNB|BOB|YES BANK|CITI|HSBC|PAYTM|GPAY)\b',
      caseSensitive: false,
    );
    final bankMatch = bankRegex.firstMatch(text);
    if (bankMatch != null) {
      final matchedBank = bankMatch.group(1)!.toUpperCase();
      // Normalize common bank names
      if (matchedBank == 'HDFC') {
        bankName = 'HDFC Bank';
      } else if (matchedBank == 'AXIS') {
        bankName = 'Axis Bank';
      } else {
        bankName = matchedBank;
      }
    }

    // 4. Parse Merchant
    String merchant = 'Unknown';
    // Look for to/at/for/by/info:/vpa: prefixes followed by alphanumeric words + slashes/hyphens/dots
    final merchantRegex = RegExp(
      r'\b(?:to|at|for|by)\s+([a-zA-Z0-9_/.\-]+)|\b(?:info:|vpa:)\s*([a-zA-Z0-9_/.\-]+)',
      caseSensitive: false,
    );
    final matches = merchantRegex.allMatches(text);
    final validMerchants = <String>[];

    for (final m in matches) {
      final group = m.group(1) ?? m.group(2);
      if (group != null && _isValidMerchant(group)) {
        validMerchants.add(_cleanMerchant(group));
      }
    }

    if (validMerchants.isNotEmpty) {
      // Prioritize non-bank merchant names if multiple matches exist
      final nonBankMerchants = validMerchants.where((m) {
        final isBank = bankRegex.hasMatch(m);
        return !isBank;
      }).toList();

      if (nonBankMerchants.isNotEmpty) {
        merchant = nonBankMerchants.first;
      } else {
        merchant = validMerchants.first;
      }
    } else {
      // Fallback: search for specific known merchants in text to be smarter
      final knownMerchants = [
        'Starbucks', 'Netflix', 'Amazon', 'Flipkart', 'Zomato', 'Swiggy', 
        'Uber', 'Ola', 'Spotify', 'Jio', 'Airtel', 'McDonalds', 'Google'
      ];
      for (final known in knownMerchants) {
        if (RegExp('\\b$known\\b', caseSensitive: false).hasMatch(text)) {
          merchant = known;
          break;
        }
      }
    }

    // 5. Infer Category
    final category = categorizeMerchant(merchant);

    // 6. Extract Card ending digits
    final cardEnding = extractCardEndingDigits(text);

    return ParsedNotification(
      amount: amount,
      type: type,
      merchant: merchant,
      category: category,
      bankName: bankName,
      cardEnding: cardEnding,
    );
  }

  static String? extractCardEndingDigits(String text) {
    // 1. Matches: card ending 1234, ending 1234, end 1234, ending in 1234, ending with 1234, a/c ending 1234, etc.
    final endingRegex = RegExp(
      r'(?:ending|end|ending in|ending with|a/c|ac)\s+(?:in\s+|with\s+)?(\d{4})',
      caseSensitive: false,
    );
    var match = endingRegex.firstMatch(text);
    if (match != null) {
      return match.group(1);
    }

    // 2. Matches: xx1234, XXXX1234, ******1234, XXXXXX672345 (extracts last 4 digits)
    final maskedRegex = RegExp(
      r'[xX*]{2,}\d*(\d{4})',
    );
    match = maskedRegex.firstMatch(text);
    if (match != null) {
      return match.group(1);
    }

    // 3. Matches general 4-digit suffix of a masked number without spacing, e.g. "x1234"
    final simpleMaskedRegex = RegExp(
      r'[xX*]+(\d{4})\b',
    );
    match = simpleMaskedRegex.firstMatch(text);
    if (match != null) {
      return match.group(1);
    }

    // 4. Matches dot prefix e.g. "...5678" or "... 5678"
    final dotPrefixRegex = RegExp(
      r'\.{2,}\s*(\d{4})\b',
    );
    match = dotPrefixRegex.firstMatch(text);
    if (match != null) {
      return match.group(1);
    }

    return null;
  }

  static bool _isValidMerchant(String name) {
    final clean = name.trim().toLowerCase();
    if (clean.isEmpty) return false;

    // Exclude currencies
    if (clean == 'rs' || clean == 'rs.' || clean == 'inr' || clean == '₹') {
      return false;
    }

    // Exclude any match that is a currency followed by numbers (e.g. rs.100, rs100)
    if (RegExp(r'^(rs\.?|inr|₹)\d', caseSensitive: false).hasMatch(clean)) {
      return false;
    }

    // Exclude account/card indicators
    if (clean == 'a/c' || clean == 'ac' || clean == 'acc' || clean == 'account' || clean == 'card' || clean == 'no' || clean == 'no.') {
      return false;
    }

    // Exclude purely numbers, dates or amounts (e.g. 500, 20-06-2026)
    if (double.tryParse(clean.replaceAll(',', '')) != null) {
      return false;
    }

    // Exclude patterns that are just dates or contain only numbers/dashes/slashes
    if (RegExp(r'^[0-9/\.\-]+$').hasMatch(clean)) {
      return false;
    }

    return true;
  }

  static String _cleanMerchant(String rawMerchant) {
    var merchant = rawMerchant.trim();
    // Remove trailing dot if any
    if (merchant.endsWith('.')) {
      merchant = merchant.substring(0, merchant.length - 1);
    }

    // Handle UPI/Merchant/TransactionId pattern (e.g. UPI/Starbucks/123)
    if (merchant.toUpperCase().startsWith('UPI/')) {
      final parts = merchant.split('/');
      if (parts.length > 1) {
        // Find first segment that is not 'UPI' and is not a number
        final cleanPart = parts.firstWhere(
          (p) => p.toUpperCase() != 'UPI' && double.tryParse(p) == null,
          orElse: () => parts[1],
        );
        return cleanPart.trim();
      }
    }

    // Clean up info: or vpa: prefix
    merchant = merchant.replaceAll(RegExp(r'^(info:|vpa:)', caseSensitive: false), '');
    return merchant.trim();
  }

  static String categorizeMerchant(String merchantName) {
    final lower = merchantName.toLowerCase().trim();
    if (lower.isEmpty) return 'Others';

    // Food & Dining
    final foodKeywords = [
      'zomato', 'swiggy', 'starbucks', 'mcdonald', 'dominos', 'pizza',
      'restaurant', 'cafe', 'bakery', 'diner', 'dhaba', 'eats', 'food'
    ];
    if (foodKeywords.any((k) => lower.contains(k))) {
      return 'Food & Dining';
    }

    // Travel & Transport
    final travelKeywords = [
      'uber', 'ola', 'rapido', 'irctc', 'metro', 'fuel', 'petrol', 'shell',
      'hpcl', 'bpcl', 'indian oil', 'cabs', 'taxi', 'flight', 'toll', 'fastag'
    ];
    if (travelKeywords.any((k) => lower.contains(k))) {
      return 'Travel & Transport';
    }

    // Bills & Utilities
    final billsKeywords = [
      'jio', 'airtel', 'vodafone', 'netflix', 'spotify', 'electricity',
      'bescom', 'water bill', 'recharge', 'insurance', 'broadband',
      'utility', 'power', 'dth'
    ];
    if (billsKeywords.any((k) => lower.contains(k))) {
      return 'Bills & Utilities';
    }

    // Shopping
    final shoppingKeywords = [
      'amazon', 'flipkart', 'myntra', 'nykaa', 'mall', 'decathlon', 'zara',
      'grocery', 'blinkit', 'instamart', 'bigbasket', 'store', 'supermarket',
      'retail'
    ];
    if (shoppingKeywords.any((k) => lower.contains(k))) {
      return 'Shopping';
    }

    // Rent
    final rentKeywords = [
      'rent', 'landlord', 'maintenance', 'flat', 'maid', 'cook', 'housing'
    ];
    if (rentKeywords.any((k) => lower.contains(k))) {
      return 'Rent';
    }

    // Salary (Credit)
    final salaryKeywords = [
      'salary', 'dividend', 'interest', 'cashback', 'refund', 'payout',
      'employer'
    ];
    if (salaryKeywords.any((k) => lower.contains(k))) {
      return 'Salary';
    }

    return 'Others';
  }
}
