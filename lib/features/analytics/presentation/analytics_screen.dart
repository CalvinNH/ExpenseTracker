import 'dart:async';
import 'package:expense_tracker/core/database/app_database.dart';
import 'package:expense_tracker/core/models/transaction.dart';
import 'package:expense_tracker/core/theme/app_theme.dart';
import 'package:expense_tracker/features/ingestion/notification_service.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({super.key});

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  bool _isLoading = true;
  List<Transaction> _transactions = [];
  Map<int, String> _accountIdToNameMap = {};
  Map<int, String> _accountIdToTypeMap = {}; // Maps ID to Wallet/Card type based on name normalization
  
  // Tab Selection
  String _activeTab = 'Categories'; // 'Categories' or 'Accounts'
  String _selectedFilter = 'This Month';
  
  // Chart interaction
  int _touchedPieIndex = -1;
  
  StreamSubscription? _transactionSubscription;

  @override
  void initState() {
    super.initState();
    _loadData();
    _transactionSubscription =
        NotificationService.onTransactionIngested.listen((_) {
      if (mounted) {
        _loadData();
      }
    });
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

      final accountMap = <int, String>{};
      final accountTypeMap = <int, String>{};

      for (final acc in accounts) {
        accountMap[acc.id!] = acc.bankName;
        accountTypeMap[acc.id!] = _normalizeAccountType(acc.bankName);
      }

      if (mounted) {
        setState(() {
          _transactions = transactions;
          _accountIdToNameMap = accountMap;
          _accountIdToTypeMap = accountTypeMap;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  String _normalizeAccountType(String bankName) {
    final lower = bankName.toLowerCase().trim();
    if (lower == 'cash' || lower.contains('cash')) {
      return 'Cash Wallet';
    }
    
    final cardKeywords = [
      'credit card', 'cc', 'card', 'credit', 'visa', 'mastercard',
      'amex', 'rupay', 'diners', 'discover', 'platina', 'signature',
      'infinite', 'onecard'
    ];

    if (cardKeywords.any((keyword) => lower.contains(keyword))) {
      return 'Credit Card';
    } else {
      return 'Bank Account';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final now = DateTime.now();
    DateTime filterStartDate;
    DateTime lastPeriodStartDate;
    DateTime lastPeriodEndDate;
    String labelLastPeriod = 'vs last month';
    
    if (_selectedFilter == 'Last 3 months') {
      filterStartDate = DateTime(now.year, now.month - 3, now.day);
      lastPeriodStartDate = DateTime(now.year, now.month - 6, now.day);
      lastPeriodEndDate = filterStartDate.subtract(const Duration(microseconds: 1));
      labelLastPeriod = 'vs previous 3m';
    } else if (_selectedFilter == 'Last year') {
      filterStartDate = DateTime(now.year - 1, now.month, now.day);
      lastPeriodStartDate = DateTime(now.year - 2, now.month, now.day);
      lastPeriodEndDate = filterStartDate.subtract(const Duration(microseconds: 1));
      labelLastPeriod = 'vs previous year';
    } else {
      // Default: 'This Month' (same as 'This month')
      filterStartDate = DateTime(now.year, now.month, 1);
      lastPeriodStartDate = DateTime(now.year, now.month - 1, 1);
      lastPeriodEndDate = filterStartDate.subtract(const Duration(microseconds: 1));
      labelLastPeriod = 'vs last month';
    }

    final currentMonthExpenses = _transactions.where((txn) {
      return txn.type == TransactionType.debit &&
          txn.timestamp.isAfter(filterStartDate.subtract(const Duration(microseconds: 1))) &&
          txn.timestamp.isBefore(now.add(const Duration(days: 1)));
    }).toList();

    final totalSpentThisMonth = currentMonthExpenses.fold<double>(0.0, (sum, txn) => sum + txn.amount);

    final lastMonthExpenses = _transactions.where((txn) {
      return txn.type == TransactionType.debit &&
          txn.timestamp.isAfter(lastPeriodStartDate.subtract(const Duration(microseconds: 1))) &&
          txn.timestamp.isBefore(lastPeriodEndDate.add(const Duration(microseconds: 1)));
    }).toList();

    final totalSpentLastMonth = lastMonthExpenses.fold<double>(0.0, (sum, txn) => sum + txn.amount);
    
    double percentChange = 0.0;
    bool isIncrease = true;
    if (totalSpentLastMonth > 0) {
      percentChange = ((totalSpentThisMonth - totalSpentLastMonth) / totalSpentLastMonth) * 100;
      isIncrease = percentChange >= 0;
      percentChange = percentChange.abs();
    } else if (totalSpentThisMonth > 0) {
      percentChange = 100.0;
      isIncrease = true;
    }

    // Category breakdown
    final Map<String, double> categoryTotals = {};
    for (final txn in currentMonthExpenses) {
      categoryTotals[txn.category] = (categoryTotals[txn.category] ?? 0.0) + txn.amount;
    }
    final sortedCategories = categoryTotals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    // Account breakdown (spending per account)
    final Map<int, double> accountTotals = {};
    final Map<int, int> accountTxnCounts = {};
    for (final txn in currentMonthExpenses) {
      accountTotals[txn.accountId] = (accountTotals[txn.accountId] ?? 0.0) + txn.amount;
      accountTxnCounts[txn.accountId] = (accountTxnCounts[txn.accountId] ?? 0) + 1;
    }

    return Scaffold(
      body: SafeArea(
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 24),
                    // Header
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Analytics',
                          style: theme.textTheme.displayLarge?.copyWith(
                            fontSize: 32,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.textDark,
                          ),
                        ),
                        PopupMenuButton<String>(
                          onSelected: (String value) {
                            setState(() {
                              _selectedFilter = value;
                              _touchedPieIndex = -1;
                            });
                          },
                          itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                            const PopupMenuItem<String>(
                              value: 'This Month',
                              child: Text('This Month'),
                            ),
                            const PopupMenuItem<String>(
                              value: 'Last 3 months',
                              child: Text('Last 3 months'),
                            ),
                            const PopupMenuItem<String>(
                              value: 'Last year',
                              child: Text('Last year'),
                            ),
                          ],
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              border: Border.all(color: AppTheme.borderLight),
                              borderRadius: BorderRadius.circular(20),
                              color: Colors.white,
                            ),
                            child: Row(
                              children: [
                                Text(
                                  _selectedFilter,
                                  style: const TextStyle(
                                    color: AppTheme.textDark,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const Icon(
                                  Icons.keyboard_arrow_down_rounded,
                                  size: 16,
                                  color: AppTheme.textDark,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    // Total Spent Card
                    Container(
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
                                'TOTAL SPENT',
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.7),
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1.2,
                                ),
                              ),
                              const Icon(
                                Icons.trending_up_rounded,
                                color: Colors.white70,
                                size: 24,
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '₹ ${totalSpentThisMonth.toStringAsFixed(2)}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 32,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 12),
                          if (totalSpentThisMonth > 0 || totalSpentLastMonth > 0)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    isIncrease ? Icons.arrow_upward : Icons.arrow_downward,
                                    size: 14,
                                    color: Colors.white,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    '${percentChange.toStringAsFixed(1)}% $labelLastPeriod',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Custom Tabs / Toggle Bar
                    Container(
                      height: 48,
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE5E7EB).withOpacity(0.5),
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: GestureDetector(
                              onTap: () {
                                setState(() {
                                  _activeTab = 'Categories';
                                  _touchedPieIndex = -1;
                                });
                              },
                              child: Container(
                                decoration: BoxDecoration(
                                  color: _activeTab == 'Categories' ? Colors.white : Colors.transparent,
                                  borderRadius: BorderRadius.circular(20),
                                  boxShadow: _activeTab == 'Categories' ? AppTheme.cardShadow : null,
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  'Categories',
                                  style: TextStyle(
                                    color: _activeTab == 'Categories' ? AppTheme.textDark : AppTheme.textMuted,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Expanded(
                            child: GestureDetector(
                              onTap: () {
                                setState(() {
                                  _activeTab = 'Accounts';
                                  _touchedPieIndex = -1;
                                });
                              },
                              child: Container(
                                decoration: BoxDecoration(
                                  color: _activeTab == 'Accounts' ? Colors.white : Colors.transparent,
                                  borderRadius: BorderRadius.circular(20),
                                  boxShadow: _activeTab == 'Accounts' ? AppTheme.cardShadow : null,
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  'Accounts',
                                  style: TextStyle(
                                    color: _activeTab == 'Accounts' ? AppTheme.textDark : AppTheme.textMuted,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Active Tab Content
                    if (_activeTab == 'Categories') ...[
                      _buildSpendingByCategorySection(totalSpentThisMonth, sortedCategories),
                      const SizedBox(height: 24),
                      _buildByAccountSection(totalSpentThisMonth, accountTotals, accountTxnCounts),
                    ] else ...[
                      _buildSpendingByAccountSection(totalSpentThisMonth, accountTotals),
                      const SizedBox(height: 24),
                      _buildByCategorySection(totalSpentThisMonth, sortedCategories),
                    ],

                    const SizedBox(height: 120),
                  ],
                ),
              ),
      ),
    );
  }

  // --- RENDERING CATEGORIES VISUALIZATION ---
  Widget _buildSpendingByCategorySection(double totalSpent, List<MapEntry<String, double>> sortedCategories) {
    if (totalSpent == 0) return _buildNoSpendingCard();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Spending by category',
          style: TextStyle(
            color: AppTheme.textDark,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            boxShadow: AppTheme.cardShadow,
          ),
          child: Row(
            children: [
              // Donut Chart
              Expanded(
                flex: 4,
                child: SizedBox(
                  height: 150,
                  child: Stack(
                    children: [
                      PieChart(
                        PieChartData(
                          pieTouchData: PieTouchData(
                            touchCallback: (FlTouchEvent event, pieTouchResponse) {
                              setState(() {
                                if (!event.isInterestedForInteractions ||
                                    pieTouchResponse == null ||
                                    pieTouchResponse.touchedSection == null) {
                                  _touchedPieIndex = -1;
                                  return;
                                }
                                _touchedPieIndex = pieTouchResponse.touchedSection!.touchedSectionIndex;
                              });
                            },
                          ),
                          borderData: FlBorderData(show: false),
                          sectionsSpace: 4,
                          centerSpaceRadius: 40,
                          sections: List.generate(sortedCategories.length, (i) {
                            final entry = sortedCategories[i];
                            final isTouched = i == _touchedPieIndex;
                            final radius = isTouched ? 28.0 : 20.0;
                            return PieChartSectionData(
                              color: AppTheme.getCategoryColor(entry.key),
                              value: entry.value,
                              title: '',
                              radius: radius,
                            );
                          }),
                        ),
                      ),
                      Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              '₹ ${totalSpent.toStringAsFixed(0)}',
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: AppTheme.textDark,
                              ),
                            ),
                            const Text(
                              'Total',
                              style: TextStyle(
                                fontSize: 10,
                                color: AppTheme.textMuted,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 16),
              // Legend
              Expanded(
                flex: 5,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: List.generate(sortedCategories.length, (index) {
                    final entry = sortedCategories[index];
                    final catColor = AppTheme.getCategoryColor(entry.key);
                    final percentage = (entry.value / totalSpent) * 100;

                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: catColor,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              entry.key,
                              style: const TextStyle(
                                color: AppTheme.textDark,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Text(
                            '${percentage.toStringAsFixed(0)}%',
                            style: const TextStyle(
                              color: AppTheme.textMuted,
                              fontSize: 11,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '₹${entry.value.toStringAsFixed(0)}',
                            style: const TextStyle(
                              color: AppTheme.textDark,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // --- RENDERING ACCOUNTS VISUALIZATION ---
  Widget _buildSpendingByAccountSection(double totalSpent, Map<int, double> accountTotals) {
    if (totalSpent == 0) return _buildNoSpendingCard();

    final sortedAccounts = accountTotals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Spending by account',
          style: TextStyle(
            color: AppTheme.textDark,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            boxShadow: AppTheme.cardShadow,
          ),
          child: Row(
            children: [
              // Donut Chart
              Expanded(
                flex: 4,
                child: SizedBox(
                  height: 150,
                  child: Stack(
                    children: [
                      PieChart(
                        PieChartData(
                          pieTouchData: PieTouchData(
                            touchCallback: (FlTouchEvent event, pieTouchResponse) {
                              setState(() {
                                if (!event.isInterestedForInteractions ||
                                    pieTouchResponse == null ||
                                    pieTouchResponse.touchedSection == null) {
                                  _touchedPieIndex = -1;
                                  return;
                                }
                                _touchedPieIndex = pieTouchResponse.touchedSection!.touchedSectionIndex;
                              });
                            },
                          ),
                          borderData: FlBorderData(show: false),
                          sectionsSpace: 4,
                          centerSpaceRadius: 40,
                          sections: List.generate(sortedAccounts.length, (i) {
                            final entry = sortedAccounts[i];
                            final isTouched = i == _touchedPieIndex;
                            final radius = isTouched ? 28.0 : 20.0;
                            // Generate unique colors for accounts based on index
                            final List<Color> accColors = [
                              AppTheme.primaryBlue,
                              AppTheme.coralAccent,
                              const Color(0xFF10B981),
                              const Color(0xFFF59E0B),
                              const Color(0xFF8B5CF6)
                            ];
                            return PieChartSectionData(
                              color: accColors[i % accColors.length],
                              value: entry.value,
                              title: '',
                              radius: radius,
                            );
                          }),
                        ),
                      ),
                      Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              '₹ ${totalSpent.toStringAsFixed(0)}',
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: AppTheme.textDark,
                              ),
                            ),
                            const Text(
                              'Total',
                              style: TextStyle(
                                fontSize: 10,
                                color: AppTheme.textMuted,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 16),
              // Legend
              Expanded(
                flex: 5,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: List.generate(sortedAccounts.length, (index) {
                    final entry = sortedAccounts[index];
                    final accName = _accountIdToNameMap[entry.key] ?? 'Unknown';
                    final percentage = (entry.value / totalSpent) * 100;
                    final List<Color> accColors = [
                      AppTheme.primaryBlue,
                      AppTheme.coralAccent,
                      const Color(0xFF10B981),
                      const Color(0xFFF59E0B),
                      const Color(0xFF8B5CF6)
                    ];

                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: accColors[index % accColors.length],
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              accName,
                              style: const TextStyle(
                                color: AppTheme.textDark,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Text(
                            '${percentage.toStringAsFixed(0)}%',
                            style: const TextStyle(
                              color: AppTheme.textMuted,
                              fontSize: 11,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '₹${entry.value.toStringAsFixed(0)}',
                            style: const TextStyle(
                              color: AppTheme.textDark,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // --- BY ACCOUNT SECTION (shows account lists with progress bars) ---
  Widget _buildByAccountSection(double totalSpent, Map<int, double> accountTotals, Map<int, int> accountTxnCounts) {
    final accountIds = _accountIdToNameMap.keys.toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'By account',
          style: TextStyle(
            color: AppTheme.textDark,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            boxShadow: AppTheme.cardShadow,
          ),
          padding: const EdgeInsets.all(8),
          child: ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: accountIds.length,
            separatorBuilder: (context, index) => const Divider(
              height: 1,
              indent: 72,
              endIndent: 16,
              color: AppTheme.borderLight,
            ),
            itemBuilder: (context, index) {
              final id = accountIds[index];
              final bankName = _accountIdToNameMap[id] ?? 'Unknown';
              final accType = _accountIdToTypeMap[id] ?? 'Bank Account';
              final spent = accountTotals[id] ?? 0.0;
              final count = accountTxnCounts[id] ?? 0;
              
              final proportion = totalSpent > 0 ? (spent / totalSpent) : 0.0;
              
              // Icon selector
              IconData accIcon = Icons.account_balance_wallet_rounded;
              Color iconBg = AppTheme.primaryBlue.withOpacity(0.12);
              Color iconColor = AppTheme.primaryBlue;

              if (accType == 'Credit Card') {
                accIcon = Icons.credit_card_rounded;
                iconBg = const Color(0xFF6B7280).withOpacity(0.12);
                iconColor = const Color(0xFF4B5563);
              }

              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: iconBg,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            accIcon,
                            color: iconColor,
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                bankName,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: AppTheme.textDark,
                                  fontSize: 16,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                count == 0 ? 'No expenses' : '$count transaction${count > 1 ? "s" : ""}',
                                style: const TextStyle(
                                  color: AppTheme.textMuted,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Text(
                          '₹ ${spent.toStringAsFixed(2)}',
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            color: AppTheme.textDark,
                            fontSize: 15,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    // Progress Bar
                    Padding(
                      padding: const EdgeInsets.only(left: 64, right: 8),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: proportion,
                          backgroundColor: AppTheme.borderLight,
                          valueColor: const AlwaysStoppedAnimation<Color>(AppTheme.coralAccent),
                          minHeight: 6,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // --- BY CATEGORY LIST SECTION (when Accounts tab is active) ---
  Widget _buildByCategorySection(double totalSpent, List<MapEntry<String, double>> sortedCategories) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'By category',
          style: TextStyle(
            color: AppTheme.textDark,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            boxShadow: AppTheme.cardShadow,
          ),
          padding: const EdgeInsets.all(8),
          child: ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: sortedCategories.length,
            separatorBuilder: (context, index) => const Divider(
              height: 1,
              indent: 72,
              endIndent: 16,
              color: AppTheme.borderLight,
            ),
            itemBuilder: (context, index) {
              final entry = sortedCategories[index];
              final category = entry.key;
              final spent = entry.value;
              final proportion = totalSpent > 0 ? (spent / totalSpent) : 0.0;
              final catColor = AppTheme.getCategoryColor(category);

              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: catColor.withOpacity(0.12),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            AppTheme.getCategoryIcon(category),
                            color: catColor,
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                category,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: AppTheme.textDark,
                                  fontSize: 16,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${(proportion * 100).toStringAsFixed(0)}% of spent',
                                style: const TextStyle(
                                  color: AppTheme.textMuted,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Text(
                          '₹ ${spent.toStringAsFixed(2)}',
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            color: AppTheme.textDark,
                            fontSize: 15,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    // Progress Bar
                    Padding(
                      padding: const EdgeInsets.only(left: 64, right: 8),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: proportion,
                          backgroundColor: AppTheme.borderLight,
                          valueColor: AlwaysStoppedAnimation<Color>(catColor),
                          minHeight: 6,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildNoSpendingCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.insights_rounded,
                size: 48,
                color: AppTheme.textMuted.withOpacity(0.5),
              ),
              const SizedBox(height: 12),
              const Text(
                'No expenses for this month',
                style: TextStyle(
                  color: AppTheme.textDark,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
