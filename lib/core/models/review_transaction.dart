import 'package:expense_tracker/core/models/parsed_financial_event.dart';
import 'package:expense_tracker/core/models/raw_notification_event.dart';

/// A retained financial notification that needs user confirmation before it
/// affects balances, spending totals, or analytics.
class ReviewTransaction {
  const ReviewTransaction({
    required this.parsedEvent,
    required this.rawEvent,
  });

  final ParsedFinancialEvent parsedEvent;
  final RawNotificationEvent rawEvent;

  DateTime get suggestedOccurredAt =>
      parsedEvent.transactionOccurredAt ?? rawEvent.postedAt;
}
