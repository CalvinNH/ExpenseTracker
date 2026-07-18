import 'dart:async';
import 'package:expense_tracker/core/database/app_database.dart';
import 'package:expense_tracker/core/models/transaction.dart';
import 'package:expense_tracker/core/theme/app_theme.dart';
import 'package:expense_tracker/features/dashboard/presentation/accounts_screen.dart';
import 'package:expense_tracker/features/ingestion/notification_service.dart';
import 'package:expense_tracker/features/transactions/presentation/add_edit_transaction_sheet.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  bool _isLoading = true;
  double _totalBalance = 0.0;
  List<Transaction> _allTransactions = [];
  List<Transaction> _recentTransactions = [];
  Map<String, double> _categoryExpenses = {};
  Map<int, String> _accountIdToNameMap = {};
  List<FlSpot> _sparklineSpots = [];
  
  bool _isSearching = false;
  final _searchController = TextEditingController();
  String _searchQuery = '';
  
  StreamSubscription? _transactionSubscription;

  @override
  void initState() {
    super.initState();
    _loadDashboardData();
    _transactionSubscription =
        NotificationService.onTransactionIngested.listen((_) {
      if (mounted) {
        _loadDashboardData();
      }
    });
  }

  @override
  void dispose() {
    _transactionSubscription?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadDashboardData() async {
    setState(() => _isLoading = true);
    try {
      final db = AppDatabase.instance;
      
      final totalBalance = await db.getTotalBalance();
      final allTransactions = await db.getAllTransactions();
      final accounts = await db.getAllAccounts();
      
      final accountMap = {
        for (final acc in accounts) acc.id!: acc.bankName,
      };

      // Filter recent 10 transactions
      final recent = allTransactions.take(10).toList();

      // Current month transactions (debits)
      final now = DateTime.now();
      final currentMonthStart = DateTime(now.year, now.month, 1);
      final nextMonthStart = DateTime(now.year, now.month + 1, 1);

      final currentMonthExpenses = allTransactions.where((txn) {
        return txn.type == TransactionType.debit &&
            txn.timestamp.isAfter(currentMonthStart.subtract(const Duration(microseconds: 1))) &&
            txn.timestamp.isBefore(nextMonthStart);
      }).toList();

      // Category expenses
      final Map<String, double> categoryMap = {};
      for (final txn in currentMonthExpenses) {
        categoryMap[txn.category] = (categoryMap[txn.category] ?? 0.0) + txn.amount;
      }

      // Generate sparkline spots (cumulative spend or daily spend)
      // Let's do cumulative spend as it forms a beautiful curve
      final Map<int, double> dailySpends = {};
      for (final txn in currentMonthExpenses) {
        final day = txn.timestamp.day;
        dailySpends[day] = (dailySpends[day] ?? 0.0) + txn.amount;
      }

      final List<FlSpot> spots = [];
      double cumulative = 0.0;
      // Generate spots for each day from 1 to the current day
      for (int d = 1; d <= now.day; d++) {
        cumulative += dailySpends[d] ?? 0.0;
        spots.add(FlSpot(d.toDouble(), cumulative));
      }

      if (spots.isEmpty) {
        spots.add(const FlSpot(1, 0));
        spots.add(FlSpot(now.day.toDouble(), 0));
      }

      if (mounted) {
        setState(() {
          _totalBalance = totalBalance;
          _allTransactions = allTransactions;
          _recentTransactions = recent;
          _categoryExpenses = categoryMap;
          _accountIdToNameMap = accountMap;
          _sparklineSpots = spots;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _openTransactionSheet([Transaction? txn]) async {
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
      _loadDashboardData();
    }
  }

  String _formatDateTime(DateTime dt) {
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
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
      ];
      return '${dt.day} ${months[dt.month - 1]} ${dt.year}';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final totalExpenses = _categoryExpenses.values.fold<double>(0.0, (sum, val) => sum + val);

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _loadDashboardData,
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  children: [
                    const SizedBox(height: 24),
                    // Header Row
                    _buildHeader(theme),
                    const SizedBox(height: 24),

                    // Balance Card
                    _buildBalanceCard(theme),
                    const SizedBox(height: 28),

                    // This Month Spending Section
                    _buildThisMonthSection(theme, totalExpenses),
                    const SizedBox(height: 28),

                    // Recent Transactions
                    _buildRecentTransactionsSection(theme),
                    const SizedBox(height: 120), // Padding for the floating bottom bar
                  ],
                ),
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    if (_isSearching) {
      return Container(
        height: 52,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(26),
          boxShadow: AppTheme.cardShadow,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            const Icon(Icons.search_rounded, color: AppTheme.textMuted, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _searchController,
                autofocus: true,
                style: const TextStyle(color: AppTheme.textDark, fontSize: 15, fontWeight: FontWeight.w600),
                decoration: const InputDecoration(
                  hintText: 'Search by merchant description...',
                  hintStyle: TextStyle(color: AppTheme.textMuted, fontSize: 14, fontWeight: FontWeight.normal),
                  border: InputBorder.none,
                  isDense: true,
                ),
                onChanged: (val) {
                  setState(() {
                    _searchQuery = val;
                  });
                },
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close_rounded, color: AppTheme.textMuted, size: 20),
              onPressed: () {
                setState(() {
                  _isSearching = false;
                  _searchQuery = '';
                  _searchController.clear();
                });
              },
            ),
          ],
        ),
      );
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: const BoxDecoration(
                color: AppTheme.primaryBlue,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.account_balance_wallet_rounded,
                color: Colors.white,
                size: 24,
              ),
            ),
            const SizedBox(width: 16),
            Text(
              'Home',
              style: theme.textTheme.displayLarge?.copyWith(
                fontSize: 32,
                fontWeight: FontWeight.bold,
                color: AppTheme.textDark,
              ),
            ),
          ],
        ),
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.search_rounded, color: AppTheme.textDark),
              onPressed: () {
                setState(() {
                  _isSearching = true;
                });
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildBalanceCard(ThemeData theme) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        gradient: AppTheme.primaryGradient,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: AppTheme.primaryBlue.withOpacity(0.24),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'TOTAL BALANCE',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.7),
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
              GestureDetector(
                onTap: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute<void>(builder: (_) => const AccountsScreen()),
                  );
                  _loadDashboardData();
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text(
                    'Accounts',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '₹ ${_totalBalance.toStringAsFixed(2)}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 36,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Across ${_accountIdToNameMap.length} linked accounts',
            style: TextStyle(
              color: Colors.white.withOpacity(0.7),
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildThisMonthSection(ThemeData theme, double totalExpenses) {
    final months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'
    ];
    final currentMonthName = months[DateTime.now().month - 1];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'This month',
              style: TextStyle(
                color: AppTheme.textDark,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            GestureDetector(
              onTap: () {
                // Let the Shell controller know or do nothing as it's tabbed
              },
              child: const Text(
                'View analytics',
                style: TextStyle(
                  color: AppTheme.primaryBlue,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            boxShadow: AppTheme.cardShadow,
          ),
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '₹ ${totalExpenses.toStringAsFixed(2)}',
                          style: const TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.textDark,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Spent in $currentMonthName',
                          style: const TextStyle(
                            color: AppTheme.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  
                  // Mini Sparkline Trend Chart
                  if (totalExpenses > 0)
                    SizedBox(
                      width: 120,
                      height: 50,
                      child: LineChart(
                        LineChartData(
                          gridData: const FlGridData(show: false),
                          titlesData: const FlTitlesData(show: false),
                          borderData: FlBorderData(show: false),
                          minX: 1,
                          maxX: DateTime.now().day.toDouble(),
                          minY: 0,
                          // Find max value in sparkline spots
                          maxY: _sparklineSpots.map((s) => s.y).reduce((a, b) => a > b ? a : b) * 1.1,
                          lineBarsData: [
                            LineChartBarData(
                              spots: _sparklineSpots,
                              isCurved: true,
                              color: AppTheme.primaryBlue,
                              barWidth: 3,
                              isStrokeCapRound: true,
                              dotData: const FlDotData(show: false),
                              belowBarData: BarAreaData(
                                show: true,
                                color: AppTheme.primaryBlue.withOpacity(0.08),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
              if (totalExpenses > 0) ...[
                const SizedBox(height: 20),
                const Divider(height: 1, color: AppTheme.borderLight),
                const SizedBox(height: 16),
                // Legend
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: _categoryExpenses.entries.map((entry) {
                    final catColor = AppTheme.getCategoryColor(entry.key);
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: catColor,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          entry.key,
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.textDark,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '₹${entry.value.toStringAsFixed(0)}',
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppTheme.textMuted,
                          ),
                        ),
                      ],
                    );
                  }).toList(),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildRecentTransactionsSection(ThemeData theme) {
    final List<Transaction> transactionsToRender;
    final bool isSearchActive = _isSearching && _searchQuery.isNotEmpty;
    
    if (isSearchActive) {
      transactionsToRender = _allTransactions
          .where((txn) => txn.merchant.toLowerCase().contains(_searchQuery.toLowerCase()))
          .toList();
    } else {
      transactionsToRender = _recentTransactions;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          isSearchActive ? 'Search results' : 'Recent transactions',
          style: const TextStyle(
            color: AppTheme.textDark,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 16),
        if (transactionsToRender.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 32),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              boxShadow: AppTheme.cardShadow,
            ),
            child: Center(
              child: Text(
                isSearchActive
                    ? 'No transactions match "$_searchQuery".'
                    : 'No transactions detected yet.',
                style: const TextStyle(color: AppTheme.textMuted),
              ),
            ),
          )
        else
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              boxShadow: AppTheme.cardShadow,
            ),
            child: ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: transactionsToRender.length,
              separatorBuilder: (context, index) => const Divider(
                height: 1,
                indent: 72,
                endIndent: 16,
                color: AppTheme.borderLight,
              ),
              itemBuilder: (context, index) {
                final txn = transactionsToRender[index];
                final isCredit = txn.type == TransactionType.credit;
                final bankName = _accountIdToNameMap[txn.accountId] ?? 'Unknown Account';
                final catColor = AppTheme.getCategoryColor(txn.category);

                return Material(
                  color: Colors.transparent,
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    leading: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: catColor.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        AppTheme.getCategoryIcon(txn.category),
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
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: AppTheme.primaryBlue.withOpacity(0.06),
                            borderRadius: BorderRadius.circular(6),
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
                      _formatDateTime(txn.timestamp),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppTheme.textMuted,
                      ),
                    ),
                    trailing: Text(
                      '${isCredit ? "+" : "-"} ₹${txn.amount.toStringAsFixed(2)}',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 16,
                        color: isCredit ? AppTheme.successGreen : AppTheme.errorRed,
                      ),
                    ),
                    onTap: () => _openTransactionSheet(txn),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}
