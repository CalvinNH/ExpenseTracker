import 'dart:async';
import 'package:expense_tracker/core/database/app_database.dart';
import 'package:expense_tracker/core/models/financial_enums.dart';
import 'package:expense_tracker/core/models/financial_presentations.dart';
import 'package:expense_tracker/core/models/review_transaction.dart';
import 'package:expense_tracker/core/models/transaction.dart';
import 'package:expense_tracker/core/theme/app_theme.dart';
import 'package:expense_tracker/features/ingestion/notification_service.dart';
import 'package:expense_tracker/features/transactions/presentation/add_edit_transaction_sheet.dart';
import 'package:flutter/material.dart';

class ActivityScreen extends StatefulWidget {
  const ActivityScreen({super.key});

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  bool _isLoading = true;
  List<Transaction> _allTransactions = [];
  List<ReviewTransaction> _reviewTransactions = [];
  Map<int, String> _accountIdToNameMap = {};
  StreamSubscription? _transactionSubscription;

  @override
  void initState() {
    super.initState();
    _loadData();
    _transactionSubscription = NotificationService.onTransactionIngested.listen(
      (_) {
        if (mounted) {
          _loadData();
        }
      },
    );
  }

  @override
  void dispose() {
    _transactionSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final db = AppDatabase.instance;
      final transactions = await db.getAllTransactions();
      final accounts = await db.getAllAccounts();
      final reviews = await db.getTransactionsForReview();

      final accountMap = {for (final acc in accounts) acc.id!: acc.bankName};

      if (mounted) {
        setState(() {
          _allTransactions = transactions;
          _reviewTransactions = reviews;
          _accountIdToNameMap = accountMap;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _openTransactionSheet(Transaction txn) async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => AddEditTransactionSheet(existingTransaction: txn),
    );
    if (result == true && mounted) {
      _loadData();
    }
  }

  Future<void> _openReviewTransaction(ReviewTransaction review) async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => AddEditTransactionSheet(reviewTransaction: review),
    );
    if (result == true && mounted) _loadData();
  }

  String _getGroupHeader(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final dateToCheck = DateTime(dt.year, dt.month, dt.day);

    if (dateToCheck == today) {
      return 'Today';
    } else if (dateToCheck == yesterday) {
      return 'Yesterday';
    } else {
      final months = [
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec',
      ];
      return '${dt.day} ${months[dt.month - 1]} ${dt.year}';
    }
  }

  String _formatTime(DateTime dt) {
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Group transactions by date
    final Map<String, List<Transaction>> grouped = {};
    for (final txn in _allTransactions) {
      final header = _getGroupHeader(txn.timestamp);
      grouped.putIfAbsent(header, () => []).add(txn);
    }

    final groupHeaders = grouped.keys.toList();

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _loadData,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              // Styled header
              SliverPadding(
                padding: const EdgeInsets.only(
                  left: 24,
                  right: 24,
                  top: 24,
                  bottom: 8,
                ),
                sliver: SliverToBoxAdapter(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Activity',
                        style: theme.textTheme.displayLarge?.copyWith(
                          fontSize: 32,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.textDark,
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.primaryBlue.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          '${_allTransactions.length + _reviewTransactions.length} items',
                          style: const TextStyle(
                            color: AppTheme.primaryBlue,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              if (_isLoading)
                const SliverFillRemaining(
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_allTransactions.isEmpty && _reviewTransactions.isEmpty)
                SliverFillRemaining(
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.receipt_long_outlined,
                          size: 72,
                          color: AppTheme.textMuted.withOpacity(0.4),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'No transactions yet',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: AppTheme.textDark,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Transactions will show up here as they occur',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: AppTheme.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              else ...[
                if (_reviewTransactions.isNotEmpty)
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
                    sliver: SliverToBoxAdapter(
                      child: _buildReviewSection(_reviewTransactions),
                    ),
                  ),
                if (_allTransactions.isNotEmpty)
                  SliverList(
                    delegate: SliverChildBuilderDelegate((context, index) {
                      final header = groupHeaders[index];
                      final txns = grouped[header]!;

                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 12,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(
                                left: 4,
                                bottom: 8,
                              ),
                              child: Text(
                                header,
                                style: theme.textTheme.titleMedium?.copyWith(
                                  color: AppTheme.textMuted,
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            Container(
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(20),
                                boxShadow: AppTheme.cardShadow,
                              ),
                              child: Material(
                                color: Colors.transparent,
                                borderRadius: BorderRadius.circular(20),
                                clipBehavior: Clip.antiAlias,
                                child: ListView.separated(
                                  shrinkWrap: true,
                                  physics: const NeverScrollableScrollPhysics(),
                                  itemCount: txns.length,
                                  separatorBuilder: (context, i) =>
                                      const Divider(
                                        height: 1,
                                        indent: 72,
                                        endIndent: 16,
                                        color: AppTheme.borderLight,
                                      ),
                                  itemBuilder: (context, i) {
                                    final txn = txns[i];
                                    final isCredit =
                                        txn.type == TransactionType.credit;
                                    final bankName =
                                        _accountIdToNameMap[txn.accountId] ??
                                        'Unknown Account';
                                    final catColor = AppTheme.getCategoryColor(
                                      txn.category,
                                    );

                                    return ListTile(
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                            horizontal: 16,
                                            vertical: 6,
                                          ),
                                      leading: Container(
                                        width: 44,
                                        height: 44,
                                        decoration: BoxDecoration(
                                          color: catColor.withOpacity(0.12),
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        child: Icon(
                                          AppTheme.getCategoryIcon(
                                            txn.category,
                                          ),
                                          color: catColor,
                                          size: 20,
                                        ),
                                      ),
                                      title: Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              txn.merchant,
                                              style: const TextStyle(
                                                fontWeight: FontWeight.bold,
                                                color: AppTheme.textDark,
                                                fontSize: 15,
                                              ),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 3,
                                            ),
                                            decoration: BoxDecoration(
                                              color: AppTheme.primaryBlue
                                                  .withOpacity(0.06),
                                              borderRadius:
                                                  BorderRadius.circular(6),
                                            ),
                                            child: Text(
                                              bankName,
                                              style: const TextStyle(
                                                fontSize: 9,
                                                fontWeight: FontWeight.bold,
                                                color: AppTheme.primaryBlue,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      subtitle: Text(
                                        _formatTime(txn.timestamp),
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              color: AppTheme.textMuted,
                                            ),
                                      ),
                                      trailing: Text(
                                        '${isCredit ? "+" : "-"} ₹${txn.amount.toStringAsFixed(2)}',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w900,
                                          fontSize: 16,
                                          color: isCredit
                                              ? AppTheme.successGreen
                                              : AppTheme.errorRed,
                                        ),
                                      ),
                                      onTap: () => _openTransactionSheet(txn),
                                    );
                                  },
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    }, childCount: groupHeaders.length),
                  ),
              ],
              // Spacer to prevent content being covered by the bottom shell nav bar (height 72 + 24 bottom padding)
              const SliverToBoxAdapter(child: SizedBox(height: 120)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTransactionStory(TransactionStory story) {
    final group = story.group;
    final merchant = group.merchantNormalized ?? 'Related transaction';
    return Card(
      key: ValueKey('transaction-story-${group.id}'),
      margin: const EdgeInsets.only(bottom: 12),
      child: ExpansionTile(
        title: Text(
          '$merchant — Net ₹${(group.netExpenseMinor / 100).toStringAsFixed(2)}',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(group.groupType.name),
        children: [
          for (final movement in story.movements)
            ListTile(
              dense: true,
              title: Text(
                '${movement.accountName}: '
                '${movement.entry.direction == FinancialDirection.credit ? '+' : '-'}'
                '₹${(movement.entry.amountMinor / 100).toStringAsFixed(2)}',
              ),
              subtitle: Text(movement.entry.eventRole.name),
            ),
          for (final event in story.informationalEvents)
            ListTile(
              dense: true,
              leading: const Icon(Icons.info_outline),
              title: Text(
                event.eventType == FinancialEventType.refund
                    ? 'Refund initiated'
                    : event.eventType.name,
              ),
              subtitle: const Text('Informational — no ledger movement'),
            ),
        ],
      ),
    );
  }

  Widget _buildReviewSection(List<ReviewTransaction> reviews) {
    final theme = Theme.of(context);
    return Container(
      key: const Key('transactions-for-review'),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: AppTheme.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
            child: Row(
              children: [
                const Icon(
                  Icons.fact_check_outlined,
                  color: AppTheme.primaryBlue,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Transactions for review',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: AppTheme.textDark,
                        ),
                      ),
                      const Text(
                        'Confirm pre-filled details to include them in tracking.',
                        style: TextStyle(
                          color: AppTheme.textMuted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  '${reviews.length}',
                  style: const TextStyle(
                    color: AppTheme.primaryBlue,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppTheme.borderLight),
          for (var index = 0; index < reviews.length; index++) ...[
            _buildReviewTile(reviews[index]),
            if (index != reviews.length - 1)
              const Divider(
                height: 1,
                indent: 72,
                color: AppTheme.borderLight,
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildReviewTile(ReviewTransaction review) {
    final parsed = review.parsedEvent;
    final isCredit = parsed.direction == FinancialDirection.credit;
    final merchant =
        parsed.merchantRaw ?? parsed.merchantNormalized ?? 'Review transaction';
    final amount = parsed.amountMinor == null
        ? 'Amount needs review'
        : '${isCredit ? '+' : '-'} â‚¹${(parsed.amountMinor! / 100).toStringAsFixed(2)}';
    final evidence = [
      if (parsed.institutionId != null) parsed.institutionId!.toUpperCase(),
      if (parsed.instrumentLastFour != null) '••${parsed.instrumentLastFour}',
      _formatTime(review.suggestedOccurredAt),
    ].join(' · ');
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      leading: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: AppTheme.primaryBlue.withOpacity(.1),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(
          Icons.edit_note_rounded,
          color: AppTheme.primaryBlue,
        ),
      ),
      title: Text(
        merchant,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontWeight: FontWeight.bold,
          color: AppTheme.textDark,
        ),
      ),
      subtitle: Text(
        evidence,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Text(
        amount,
        style: TextStyle(
          fontWeight: FontWeight.w800,
          color: isCredit ? AppTheme.successGreen : AppTheme.errorRed,
        ),
      ),
      onTap: () => _openReviewTransaction(review),
    );
  }
}
