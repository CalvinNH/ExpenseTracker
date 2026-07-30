import 'package:collection/collection.dart';
import 'package:expense_tracker/core/database/app_database.dart';
import 'package:expense_tracker/core/models/financial_enums.dart';
import 'package:expense_tracker/core/models/money.dart';
import 'package:expense_tracker/core/models/review_transaction.dart';
import 'package:expense_tracker/core/services/manual_transaction_service.dart';
import 'package:expense_tracker/core/models/account.dart';
import 'package:expense_tracker/core/models/transaction.dart';
import 'package:expense_tracker/core/theme/app_theme.dart';
import 'package:expense_tracker/core/widgets/app_toast.dart';
import 'package:expense_tracker/features/ingestion/notification_parser.dart';
import 'package:expense_tracker/features/ingestion/notification_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AddEditTransactionSheet extends StatefulWidget {
  const AddEditTransactionSheet({
    super.key,
    this.existingTransaction,
    this.reviewTransaction,
  }) : assert(existingTransaction == null || reviewTransaction == null);

  final Transaction? existingTransaction;
  final ReviewTransaction? reviewTransaction;

  @override
  State<AddEditTransactionSheet> createState() =>
      _AddEditTransactionSheetState();
}

class _AddEditTransactionSheetState extends State<AddEditTransactionSheet> {
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  final _merchantController = TextEditingController();

  TransactionType _selectedType = TransactionType.debit;
  String _selectedCategory = 'Others';
  int? _selectedAccountId;
  DateTime _selectedDateTime = DateTime.now();

  List<Account> _accounts = [];
  bool _isLoadingAccounts = true;
  bool _isSaving = false;

  bool get _isEditing => widget.existingTransaction != null;
  bool get _isReviewing => widget.reviewTransaction != null;

  static const _categories = [
    'Food & Dining',
    'Shopping',
    'Bills & Utilities',
    'Travel & Transport',
    'Rent',
    'Salary',
    'Others',
  ];

  @override
  void initState() {
    super.initState();
    _loadAccounts();

    final existing = widget.existingTransaction;
    if (existing != null) {
      _amountController.text = existing.amount.toStringAsFixed(2);
      _merchantController.text = existing.merchant;
      _selectedType = existing.type;
      _selectedCategory = _categories.contains(existing.category)
          ? existing.category
          : 'Others';
      _selectedAccountId = existing.accountId;
      _selectedDateTime = existing.timestamp;
    }
    final review = widget.reviewTransaction;
    if (review != null) {
      final parsed = review.parsedEvent;
      _amountController.text = minorToMajor(parsed.amountMinor!).toStringAsFixed(2);
      _merchantController.text =
          parsed.merchantRaw ?? parsed.merchantNormalized ?? 'Unspecified merchant';
      _selectedType = parsed.direction == FinancialDirection.credit
          ? TransactionType.credit
          : TransactionType.debit;
      final category = NotificationParser.categorizeMerchant(
        parsed.merchantNormalized ?? parsed.merchantRaw ?? '',
      );
      _selectedCategory = _categories.contains(category) ? category : 'Others';
      _selectedDateTime = review.suggestedOccurredAt;
    }
  }

  @override
  void dispose() {
    _amountController.dispose();
    _merchantController.dispose();
    super.dispose();
  }

  Future<void> _loadAccounts() async {
    final accounts = await AppDatabase.instance.getAllAccounts();
    if (mounted) {
      setState(() {
        _accounts = accounts;
        _isLoadingAccounts = false;
        if (_isReviewing) {
          final parsed = widget.reviewTransaction!.parsedEvent;
          final matchingInstrument = accounts.where(
            (account) =>
                parsed.instrumentLastFour != null &&
                account.lastFour == parsed.instrumentLastFour,
          );
          final matchingInstitution = matchingInstrument.where(
            (account) =>
                parsed.institutionId != null &&
                account.institutionId == parsed.institutionId,
          );
          _selectedAccountId = (matchingInstitution.isNotEmpty
                  ? matchingInstitution.first
                  : matchingInstrument.isNotEmpty
                  ? matchingInstrument.first
                  : accounts.where(
                      (account) =>
                          parsed.institutionId != null &&
                          account.institutionId == parsed.institutionId,
                    ).firstOrNull)
              ?.id;
        } else if (!_isEditing && accounts.length == 1) {
          _selectedAccountId = accounts.first.id;
        }
      });
    }
  }

  Future<void> _selectDateTime() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _selectedDateTime,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: AppTheme.primaryBlue,
              onPrimary: Colors.white,
              onSurface: AppTheme.textDark,
            ),
          ),
          child: child!,
        );
      },
    );

    if (date == null) return;

    if (!mounted) return;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_selectedDateTime),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: AppTheme.primaryBlue,
              onPrimary: Colors.white,
              onSurface: AppTheme.textDark,
            ),
          ),
          child: child!,
        );
      },
    );

    if (time == null) return;

    setState(() {
      _selectedDateTime = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
    });
  }

  Future<void> _pasteAndParseSmsText() async {
    final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
    final text = clipboardData?.text?.trim();

    if (text == null || text.isEmpty) {
      if (mounted) AppToast.show(context, 'Clipboard is empty');
      return;
    }

    final parsed = NotificationParser.parse('SMS', text);
    if (parsed == null) {
      if (mounted) {
        AppToast.show(
          context,
          'Could not parse transaction from pasted text',
          isError: true,
        );
      }
      return;
    }

    setState(() {
      _amountController.text = parsed.amount.toStringAsFixed(2);
      _merchantController.text = parsed.merchant;
      _selectedType = parsed.type;
      if (_categories.contains(parsed.category)) {
        _selectedCategory = parsed.category;
      }

      if (_accounts.isNotEmpty) {
        final bankCode = NotificationService.extractBankCode(parsed.bankName);
        final cardEnding = parsed.cardEnding;

        Account? matched;
        if (cardEnding != null && cardEnding.isNotEmpty) {
          matched = _accounts.firstWhereOrNull(
            (acc) =>
                acc.bankName.toLowerCase().contains(bankCode) &&
                acc.bankName.contains(cardEnding),
          );
          matched ??= _accounts.firstWhereOrNull(
            (acc) => acc.bankName.contains(cardEnding),
          );
        }
        matched ??= _accounts.firstWhereOrNull(
          (acc) => acc.bankName.toLowerCase().contains(bankCode),
        );
        matched ??= _accounts.first;

        _selectedAccountId = matched.id;
      }
    });

    if (mounted) {
      AppToast.show(context, 'Auto-filled details from SMS text!');
    }
  }

  void _showCategoryPicker() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppTheme.textMuted.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Select Category',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.textDark,
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _categories.length,
                  itemBuilder: (context, index) {
                    final cat = _categories[index];
                    final isSelected = cat == _selectedCategory;
                    final color = AppTheme.getCategoryColor(cat);

                    return ListTile(
                      leading: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: color.withOpacity(0.12),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          AppTheme.getCategoryIcon(cat),
                          color: color,
                          size: 18,
                        ),
                      ),
                      title: Text(
                        cat,
                        style: TextStyle(
                          fontWeight: isSelected
                              ? FontWeight.bold
                              : FontWeight.normal,
                          color: AppTheme.textDark,
                        ),
                      ),
                      trailing: isSelected
                          ? const Icon(
                              Icons.check_circle_rounded,
                              color: AppTheme.primaryBlue,
                            )
                          : null,
                      onTap: () {
                        setState(() => _selectedCategory = cat);
                        Navigator.pop(context);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showAccountPicker() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppTheme.textMuted.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Select Account',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.textDark,
                ),
              ),
              const SizedBox(height: 8),
              if (_accounts.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('No accounts configured'),
                )
              else
                Expanded(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: _accounts.length,
                    itemBuilder: (context, index) {
                      final acc = _accounts[index];
                      final isSelected = acc.id == _selectedAccountId;
                      final isCard =
                          acc.accountType == AccountType.creditCard ||
                          acc.accountType == AccountType.debitCard;

                      return ListTile(
                        leading: Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: (isCard ? Colors.grey : AppTheme.primaryBlue)
                                .withOpacity(0.12),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            isCard
                                ? Icons.credit_card_rounded
                                : Icons.account_balance_wallet_rounded,
                            color: isCard
                                ? Colors.grey[700]
                                : AppTheme.primaryBlue,
                            size: 18,
                          ),
                        ),
                        title: Text(
                          acc.bankName,
                          style: TextStyle(
                            fontWeight: isSelected
                                ? FontWeight.bold
                                : FontWeight.normal,
                            color: AppTheme.textDark,
                          ),
                        ),
                        trailing: isSelected
                            ? const Icon(
                                Icons.check_circle_rounded,
                                color: AppTheme.primaryBlue,
                              )
                            : null,
                        onTap: () {
                          setState(() => _selectedAccountId = acc.id);
                          Navigator.pop(context);
                        },
                      );
                    },
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_selectedAccountId == null) {
      AppToast.show(context, 'Please select an account', isError: true);
      return;
    }

    setState(() => _isSaving = true);

    try {
      final amount = double.parse(_amountController.text.trim());
      final merchant = _merchantController.text.trim();
      if (_isEditing) {
        final manualTransactions = ManualTransactionService();
        final updated = widget.existingTransaction!.copyWith(
          amount: amount,
          type: _selectedType,
          merchant: merchant,
          category: _selectedCategory,
          accountId: _selectedAccountId,
          timestamp: _selectedDateTime,
        );
        await manualTransactions.update(updated);
      } else {
        final newTxn = Transaction(
          amount: amount,
          type: _selectedType,
          timestamp: _selectedDateTime,
          merchant: merchant,
          category: _selectedCategory,
          accountId: _selectedAccountId!,
        );
        if (_isReviewing) {
          await AppDatabase.instance.resolveReviewedTransaction(
            parsedFinancialEventId: widget.reviewTransaction!.parsedEvent.id!,
            transaction: newTxn,
          );
        } else {
          await ManualTransactionService().create(newTxn);
        }
      }

      NotificationService.notifyTransactionIngested();
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        AppToast.show(context, 'Error saving: $e', isError: true);
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        title: const Text(
          'Delete Transaction',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: AppTheme.textDark,
          ),
        ),
        content: const Text(
          'This will reverse the balance effect and permanently remove this transaction. Continue?',
          style: TextStyle(color: AppTheme.textMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.errorRed),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isSaving = true);
    try {
      await ManualTransactionService().delete(widget.existingTransaction!.id!);
      NotificationService.notifyTransactionIngested();
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        AppToast.show(context, 'Error deleting: $e', isError: true);
        setState(() => _isSaving = false);
      }
    }
  }

  String _formatSelectedDate(DateTime dt) {
    final day = dt.day.toString().padLeft(2, '0');
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
    final year = dt.year;
    final minute = dt.minute.toString().padLeft(2, '0');
    final period = dt.hour >= 12 ? 'PM' : 'AM';
    final formatHour = dt.hour > 12
        ? dt.hour - 12
        : (dt.hour == 0 ? 12 : dt.hour);
    return '$day ${months[dt.month - 1]} $year · ${formatHour.toString().padLeft(2, '0')}:$minute $period';
  }

  Widget _buildSelectorTile({
    required String label,
    required String value,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
    Key? key,
  }) {
    return GestureDetector(
      key: key,
      onTap: onTap,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: AppTheme.cardShadow,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: color.withOpacity(0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: color, size: 16),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      color: AppTheme.textMuted,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    value,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.textDark,
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(
              Icons.keyboard_arrow_down_rounded,
              color: AppTheme.textMuted,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    final selectedAccName = _accounts
        .firstWhere(
          (a) => a.id == _selectedAccountId,
          orElse: () => Account(bankName: 'Select Account', currentBalance: 0),
        )
        .bankName;

    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.background,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 20,
        bottom: bottomInset + 24,
      ),
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header Indicator
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppTheme.textMuted.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Title Row
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      _isEditing
                          ? 'Edit transaction'
                          : _isReviewing
                          ? 'Review transaction'
                          : 'Add transaction',
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.textDark,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Row(
                    children: [
                      if (_isEditing)
                        IconButton(
                          onPressed: _isSaving ? null : _delete,
                          icon: const Icon(Icons.delete_outline_rounded),
                          color: AppTheme.errorRed,
                          tooltip: 'Delete Transaction',
                        ),
                      GestureDetector(
                        onTap: () => Navigator.pop(context),
                        child: Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            border: Border.all(color: AppTheme.borderLight),
                            shape: BoxShape.circle,
                            color: Colors.white,
                          ),
                          child: const Icon(
                            Icons.close_rounded,
                            size: 18,
                            color: AppTheme.textDark,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),

              if (!_isEditing && !_isReviewing) ...[
                const SizedBox(height: 12),
                InkWell(
                  onTap: _pasteAndParseSmsText,
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.primaryBlue.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: AppTheme.primaryBlue.withOpacity(0.2),
                      ),
                    ),
                    child: const Row(
                      children: [
                        Icon(
                          Icons.content_paste_go_rounded,
                          size: 18,
                          color: AppTheme.primaryBlue,
                        ),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Paste & Auto-Fill from SMS',
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.primaryBlue,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 24),

              // Expense / Income Toggle
              Container(
                width: double.infinity,
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
                        onTap: () => setState(
                          () => _selectedType = TransactionType.debit,
                        ),
                        child: Container(
                          decoration: BoxDecoration(
                            color: _selectedType == TransactionType.debit
                                ? AppTheme.textDark
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          alignment: Alignment.center,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (_selectedType == TransactionType.debit)
                                const Icon(
                                  Icons.check_rounded,
                                  color: Colors.white,
                                  size: 16,
                                ),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  'Expense',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color:
                                        _selectedType == TransactionType.debit
                                        ? Colors.white
                                        : AppTheme.textMuted,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: GestureDetector(
                        onTap: () => setState(
                          () => _selectedType = TransactionType.credit,
                        ),
                        child: Container(
                          decoration: BoxDecoration(
                            color: _selectedType == TransactionType.credit
                                ? AppTheme.textDark
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          alignment: Alignment.center,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (_selectedType == TransactionType.credit)
                                const Icon(
                                  Icons.check_rounded,
                                  color: Colors.white,
                                  size: 16,
                                ),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  'Income',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color:
                                        _selectedType == TransactionType.credit
                                        ? Colors.white
                                        : AppTheme.textMuted,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // Amount Section
              const Text(
                'Amount',
                style: TextStyle(
                  color: AppTheme.textMuted,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              TextFormField(
                controller: _amountController,
                style: const TextStyle(
                  fontSize: 36,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.textDark,
                ),
                decoration: const InputDecoration(
                  prefixText: '₹ ',
                  prefixStyle: TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.textDark,
                  ),
                  hintText: '0.00',
                  hintStyle: TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFD1D5DB),
                  ),
                  border: InputBorder.none,
                ),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
                ],
                validator: (value) {
                  final text = value?.trim() ?? '';
                  if (text.isEmpty) return 'Enter an amount';
                  final parsed = double.tryParse(text);
                  if (parsed == null || parsed <= 0) {
                    return 'Amount must be greater than 0';
                  }
                  return null;
                },
              ),
              const Text(
                'Enter the transaction amount',
                style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
              ),
              const SizedBox(height: 24),

              // Merchant / Description
              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: AppTheme.cardShadow,
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Merchant or Description',
                      style: TextStyle(
                        color: AppTheme.textMuted,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    TextFormField(
                      controller: _merchantController,
                      style: const TextStyle(
                        color: AppTheme.textDark,
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.only(top: 6, bottom: 4),
                        hintText: 'Starbucks, Rent, Salary',
                        hintStyle: TextStyle(
                          color: Color(0xFFD1D5DB),
                          fontWeight: FontWeight.normal,
                        ),
                      ),
                      textCapitalization: TextCapitalization.words,
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Enter description';
                        }
                        return null;
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Category Selector
              _buildSelectorTile(
                key: const Key('transaction-category-selector'),
                label: 'Category',
                value: _selectedCategory,
                icon: AppTheme.getCategoryIcon(_selectedCategory),
                color: AppTheme.getCategoryColor(_selectedCategory),
                onTap: _showCategoryPicker,
              ),
              const SizedBox(height: 16),

              // Account Selector
              _isLoadingAccounts
                  ? const Center(child: CircularProgressIndicator())
                  : _buildSelectorTile(
                      key: const Key('transaction-account-selector'),
                      label: 'Account',
                      value: selectedAccName,
                      icon: Icons.account_balance_wallet_rounded,
                      color: AppTheme.primaryBlue,
                      onTap: _showAccountPicker,
                    ),
              const SizedBox(height: 16),

              // Date Selector
              _buildSelectorTile(
                key: const Key('transaction-date-selector'),
                label: 'Date and Time',
                value: _formatSelectedDate(_selectedDateTime),
                icon: Icons.calendar_today_rounded,
                color: AppTheme.primaryBlue,
                onTap: _selectDateTime,
              ),
              const SizedBox(height: 32),

              // Save Button
              SizedBox(
                width: double.infinity,
                height: 54,
                child: FilledButton(
                  onPressed: _isSaving ? null : _save,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.primaryBlue,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(27),
                    ),
                    elevation: 0,
                  ),
                  child: _isSaving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Text(
                          _isEditing
                              ? 'Update'
                              : (_selectedType == TransactionType.debit
                                    ? 'Add expense'
                                    : 'Add income'),
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
