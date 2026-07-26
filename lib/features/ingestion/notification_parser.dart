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

  /// Sanity ceiling for a single parsed transaction (₹1 crore).
  /// Rejects garbage matches and digit strings that overflow to
  /// double.infinity.
  static const double _maxAmount = 10000000;

  static ParsedNotification? parse(String title, String content) {
    final text = _normalizeText('$title $content');
    if (RegExp(
      r'\b(otp|one[ -]?time password|verification code)\b',
      caseSensitive: false,
    ).hasMatch(text)) {
      return null;
    }

    // 1. Parse Amount
    // Supports ₹, Rs/Rs., INR and common optional separators.
    final amountRegex = RegExp(
      r'(?:₹|rs\.?|inr)\s*[:\-]?\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)',
      caseSensitive: false,
    );
    final amountMatch = amountRegex.firstMatch(text);
    if (amountMatch == null) {
      return null; // A valid transaction notification must have an amount
    }

    final amountStr = amountMatch.group(1)!.replaceAll(',', '');
    final amount = double.tryParse(amountStr);
    if (amount == null ||
        !amount.isFinite ||
        amount <= 0 ||
        amount > _maxAmount) {
      return null;
    }

    // 2. Parse Transaction Type
    final creditKeywords = RegExp(
      r'\b(credited|credit|received|deposited|deposit|added|refunded|refund|cashback|reversed|reversal|cr)\b',
      caseSensitive: false,
    );
    final debitKeywords = RegExp(
      r'\b(debited|debit|spent|withdrawn|withdrawal|sent|paid|payment|purchased|purchase|deducted|transferred|txn|dr)\b',
      caseSensitive: false,
    );

    final hasCredit = creditKeywords.hasMatch(text);
    final hasDebit = debitKeywords.hasMatch(text);
    if (!hasCredit && !hasDebit) {
      // Do not turn balance summaries, OTPs, offers, or bill reminders that
      // merely contain a currency amount into expenses.
      return null;
    }

    // Reversal/refund notifications often mention the original debit as well.
    final type = hasCredit ? TransactionType.credit : TransactionType.debit;

    // 3. Parse Bank Name
    String bankName = 'Unknown Bank';
    final bankRegex = RegExp(
      r'\b(HDFC|SBI|STATE BANK OF INDIA|ICICI|AXIS|KOTAK|PNB|PUNJAB NATIONAL BANK|BOB|BANK OF BARODA|YES BANK|CITI|CITIBANK|HSBC|IDFC|INDUSIND|CANARA|UNION BANK|FEDERAL BANK|RBL|PAYTM|GPAY)\b',
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
      } else if (matchedBank == 'STATE BANK OF INDIA') {
        bankName = 'SBI';
      } else if (matchedBank == 'PUNJAB NATIONAL BANK') {
        bankName = 'PNB';
      } else if (matchedBank == 'BANK OF BARODA') {
        bankName = 'BOB';
      } else if (matchedBank == 'CITIBANK') {
        bankName = 'CITI';
      } else {
        bankName = matchedBank;
      }
    }

    // 4. Parse Merchant
    String merchant = 'Unknown';
    // Capture multi-word payee names, UPI references, and VPA identifiers.
    // Stop before the next piece of banking metadata rather than at a space.
    final merchantRegex = RegExp(
      r'\b(?:to|at|for|towards|merchant)\s*[:\-]?\s+([a-zA-Z0-9][a-zA-Z0-9 _/@.&\-]{0,80}?)(?=\s+(?:on|via|using|ref|txn|transaction|avl|available|bal|balance|from|a/c|account|card)\b|[.;,]|$)|\b(?:info|vpa|upi ref)\s*:\s*([a-zA-Z0-9_/@.\-& ]{1,80}?)(?=[.;,]|$)',
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
      final upiMatch = RegExp(
        r'\bUPI[/\-]([A-Za-z][A-Za-z0-9 .&_-]{1,60}?)(?:[/\-]\d+|\s|[.;,]|$)',
        caseSensitive: false,
      ).firstMatch(text);
      if (upiMatch != null && _isValidMerchant(upiMatch.group(1)!)) {
        merchant = _cleanMerchant(upiMatch.group(1)!);
      }

      final knownMerchants = [
        'Starbucks',
        'Netflix',
        'Amazon',
        'Flipkart',
        'Zomato',
        'Swiggy',
        'Uber',
        'Ola',
        'Spotify',
        'Jio',
        'Airtel',
        'McDonalds',
        'Google',
        'Blinkit',
        'Zepto',
        'BigBasket',
        'Myntra',
        'IRCTC',
        'Rapido',
      ];
      if (merchant == 'Unknown') {
        for (final known in knownMerchants) {
          if (RegExp('\\b$known\\b', caseSensitive: false).hasMatch(text)) {
            merchant = known;
            break;
          }
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

  static String _normalizeText(String input) {
    return input
        .replaceAll('\u00a0', ' ')
        .replaceAll(RegExp(r'[\r\n\t]+'), ' ')
        .replaceAll(RegExp(r'\s{2,}'), ' ')
        .trim();
  }

  static String? extractCardEndingDigits(String text) {
    // 1. Matches: A/c 2962, A/C: 2962, Card 2962, Account no. 2962, ending in 2962
    final accountNoRegex = RegExp(
      r'(?:a/c|ac|account|card)\s*(?:no\.?|number)?\s*[:.*]*\s*(\d{4})\b',
      caseSensitive: false,
    );
    var match = accountNoRegex.firstMatch(text);
    if (match != null) {
      return match.group(1);
    }

    // 2. Matches: card ending 1234, ending 1234, end 1234, ending in 1234, ending with 1234, a/c ending 1234, etc.
    final endingRegex = RegExp(
      r'(?:ending|end|ending in|ending with|a/c|ac)\s+(?:in\s+|with\s+)?(\d{4})',
      caseSensitive: false,
    );
    match = endingRegex.firstMatch(text);
    if (match != null) {
      return match.group(1);
    }

    // 3. Matches: xx1234, XXXX1234, ******1234, XXXXXX672345.
    final maskedRegex = RegExp(r'[xX*]{1,}(\d{4,})\b');
    match = maskedRegex.firstMatch(text);
    if (match != null) {
      final digits = match.group(1)!;
      return digits.substring(digits.length - 4);
    }

    // 4. Matches general 4-digit suffix of a masked number without spacing, e.g. "x1234"
    final simpleMaskedRegex = RegExp(r'[xX*]+(\d{4})\b');
    match = simpleMaskedRegex.firstMatch(text);
    if (match != null) {
      return match.group(1);
    }

    // 5. Matches dot prefix e.g. "...5678" or "... 5678"
    final dotPrefixRegex = RegExp(r'\.{2,}\s*(\d{4})\b');
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
    if (clean == 'a/c' ||
        clean == 'ac' ||
        clean == 'acc' ||
        clean == 'account' ||
        clean == 'card' ||
        clean == 'no' ||
        clean == 'no.') {
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

    // Clean up metadata and VPA handles while preserving readable payee names.
    merchant = merchant.replaceAll(
      RegExp(r'^(info:|vpa:)', caseSensitive: false),
      '',
    );
    merchant = merchant.replaceAll(RegExp(r'\s+'), ' ');
    merchant = merchant.replaceAll(
      RegExp(r'\s*(?:upi|ref|txn)\s*$', caseSensitive: false),
      '',
    );
    return merchant.trim();
  }

  static String categorizeMerchant(String merchantName) {
    final lower = merchantName.toLowerCase().trim();
    if (lower.isEmpty) return 'Others';

    // Food & Dining
    final foodKeywords = [
      'zomato',
      'swiggy',
      'starbucks',
      'mcdonald',
      'dominos',
      'pizza',
      'restaurant',
      'cafe',
      'bakery',
      'diner',
      'dhaba',
      'eats',
      'food',
    ];
    if (foodKeywords.any((k) => lower.contains(k))) {
      return 'Food & Dining';
    }

    // Travel & Transport
    final travelKeywords = [
      'uber',
      'ola',
      'rapido',
      'irctc',
      'metro',
      'fuel',
      'petrol',
      'shell',
      'hpcl',
      'bpcl',
      'indian oil',
      'cabs',
      'taxi',
      'flight',
      'toll',
      'fastag',
    ];
    if (travelKeywords.any((k) => lower.contains(k))) {
      return 'Travel & Transport';
    }

    // Bills & Utilities
    final billsKeywords = [
      'jio',
      'airtel',
      'vodafone',
      'netflix',
      'spotify',
      'electricity',
      'bescom',
      'water bill',
      'recharge',
      'insurance',
      'broadband',
      'utility',
      'power',
      'dth',
    ];
    if (billsKeywords.any((k) => lower.contains(k))) {
      return 'Bills & Utilities';
    }

    // Shopping
    final shoppingKeywords = [
      'amazon',
      'flipkart',
      'myntra',
      'nykaa',
      'mall',
      'decathlon',
      'zara',
      'grocery',
      'blinkit',
      'instamart',
      'bigbasket',
      'store',
      'supermarket',
      'retail',
    ];
    if (shoppingKeywords.any((k) => lower.contains(k))) {
      return 'Shopping';
    }

    // Rent
    final rentKeywords = [
      'rent',
      'landlord',
      'maintenance',
      'flat',
      'maid',
      'cook',
      'housing',
    ];
    if (rentKeywords.any((k) => lower.contains(k))) {
      return 'Rent';
    }

    // Salary (Credit)
    final salaryKeywords = [
      'salary',
      'dividend',
      'interest',
      'cashback',
      'refund',
      'payout',
      'employer',
    ];
    if (salaryKeywords.any((k) => lower.contains(k))) {
      return 'Salary';
    }

    return 'Others';
  }
}
