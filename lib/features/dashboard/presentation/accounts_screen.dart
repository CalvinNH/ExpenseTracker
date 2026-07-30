import 'package:expense_tracker/core/database/app_database.dart';
import 'package:expense_tracker/core/models/account.dart';
import 'package:expense_tracker/core/models/financial_enums.dart';
import 'package:expense_tracker/core/theme/app_theme.dart';
import 'package:expense_tracker/core/widgets/app_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AccountsScreen extends StatefulWidget {
  const AccountsScreen({super.key});

  @override
  State<AccountsScreen> createState() => _AccountsScreenState();
}

class _AccountsScreenState extends State<AccountsScreen> {
  bool _isLoading = true;
  List<Account> _accounts = [];

  final _addFormKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _balanceController = TextEditingController();
  final _cardEndingController = TextEditingController();
  final _institutionController = TextEditingController();
  final _upiController = TextEditingController();
  String _selectedType = 'Bank'; // 'Bank', 'Card', 'Cash'
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _loadAccounts();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _balanceController.dispose();
    _cardEndingController.dispose();
    _institutionController.dispose();
    _upiController.dispose();
    super.dispose();
  }

  Future<void> _loadAccounts() async {
    setState(() => _isLoading = true);
    try {
      final accounts = await AppDatabase.instance.getAllAccounts();
      if (mounted) {
        setState(() {
          _accounts = accounts;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  String _getAccountIconPath(Account account) {
    if (account.accountType == AccountType.cash) {
      return 'assets/icon/account_cash.png';
    } else if (account.accountType == AccountType.creditCard ||
        account.accountType == AccountType.debitCard) {
      return 'assets/icon/account_card.png';
    } else {
      return 'assets/icon/account_bank.png';
    }
  }

  String _getAccountTypeLabel(Account account) => switch (account.accountType) {
    AccountType.creditCard => 'Credit Card',
    AccountType.debitCard => 'Debit Card',
    AccountType.wallet => 'Wallet',
    AccountType.cash => 'Cash Wallet',
    AccountType.bankAccount => 'Bank Account',
    AccountType.unknown => 'Account',
  };

  Future<void> _showAddAccountDialog() async {
    _nameController.clear();
    _balanceController.clear();
    _cardEndingController.clear();
    _institutionController.clear();
    _upiController.clear();
    setState(() {
      _selectedType = 'Bank';
    });

    await showDialog(
      context: context,
      barrierDismissible: !_isSaving,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: Colors.white,
              surfaceTintColor: Colors.transparent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              title: const Text(
                'Add Account',
                style: TextStyle(
                  color: AppTheme.textDark,
                  fontWeight: FontWeight.bold,
                ),
              ),
              content: Form(
                key: _addFormKey,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Type selector
                      const Text(
                        'Account Type',
                        style: TextStyle(
                          color: AppTheme.textMuted,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        height: 44,
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE5E7EB).withOpacity(0.5),
                          borderRadius: BorderRadius.circular(22),
                        ),
                        child: Row(
                          children: [
                            _buildTypeButton('Bank', 'Bank', setDialogState),
                            _buildTypeButton('Card', 'Card', setDialogState),
                            _buildTypeButton(
                              'Wallet',
                              'Wallet',
                              setDialogState,
                            ),
                            _buildTypeButton('Cash', 'Cash', setDialogState),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),

                      // Name / Card ending Fields
                      if (_selectedType == 'Card')
                        Row(
                          children: [
                            Expanded(
                              flex: 3,
                              child: TextFormField(
                                controller: _nameController,
                                decoration: const InputDecoration(
                                  labelText: 'Card Name',
                                  hintText: 'e.g. Regalia',
                                  border: OutlineInputBorder(),
                                ),
                                textCapitalization: TextCapitalization.words,
                                validator: (value) {
                                  if (value == null || value.trim().isEmpty) {
                                    return 'Enter name';
                                  }
                                  return null;
                                },
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              flex: 2,
                              child: TextFormField(
                                controller: _cardEndingController,
                                decoration: const InputDecoration(
                                  labelText: 'Last 4 digits',
                                  hintText: '1234',
                                  border: OutlineInputBorder(),
                                  counterText: '',
                                ),
                                keyboardType: TextInputType.number,
                                maxLength: 4,
                                inputFormatters: [
                                  FilteringTextInputFormatter.digitsOnly,
                                ],
                                validator: (value) {
                                  final text = value?.trim() ?? '';
                                  if (text.isNotEmpty && text.length != 4) {
                                    return 'Use 4 digits';
                                  }
                                  return null;
                                },
                              ),
                            ),
                          ],
                        )
                      else
                        TextFormField(
                          controller: _nameController,
                          decoration: const InputDecoration(
                            labelText: 'Account Name',
                            hintText: 'e.g. SBI Savings',
                            border: OutlineInputBorder(),
                          ),
                          textCapitalization: TextCapitalization.words,
                          validator: (value) {
                            if (value == null || value.trim().isEmpty) {
                              return 'Please enter account name';
                            }
                            return null;
                          },
                        ),
                      const SizedBox(height: 16),
                      if (_selectedType != 'Cash') ...[
                        TextFormField(
                          controller: _institutionController,
                          decoration: const InputDecoration(
                            labelText: 'Institution',
                            hintText:
                                'Bank, payment app, or custom institution',
                            border: OutlineInputBorder(),
                          ),
                          textCapitalization: TextCapitalization.words,
                        ),
                        const SizedBox(height: 16),
                      ],
                      if (_selectedType == 'Bank' ||
                          _selectedType == 'Wallet') ...[
                        TextFormField(
                          controller: _upiController,
                          decoration: const InputDecoration(
                            labelText: 'UPI handle (optional)',
                            hintText: 'name@bank',
                            border: OutlineInputBorder(),
                          ),
                          keyboardType: TextInputType.emailAddress,
                        ),
                        const SizedBox(height: 16),
                      ],

                      // Balance Field
                      TextFormField(
                        controller: _balanceController,
                        decoration: const InputDecoration(
                          labelText: 'Current Balance',
                          prefixText: '₹ ',
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                          signed: true,
                        ),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(
                            RegExp(r'^-?\d*\.?\d{0,2}'),
                          ),
                        ],
                        validator: (value) {
                          final text = value?.trim() ?? '';
                          if (text.isEmpty) {
                            return 'Please enter current balance';
                          }
                          if (double.tryParse(text) == null) {
                            return 'Enter a valid amount';
                          }
                          return null;
                        },
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: _isSaving ? null : () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.primaryBlue,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                  onPressed: _isSaving
                      ? null
                      : () async {
                          if (!_addFormKey.currentState!.validate()) {
                            return;
                          }

                          setDialogState(() => _isSaving = true);
                          try {
                            String name = _nameController.text.trim();
                            final balance = double.parse(
                              _balanceController.text.trim(),
                            );

                            // Deduce or enforce name format matching selected type
                            if (_selectedType == 'Card') {
                              final ending = _cardEndingController.text.trim();
                              final lower = name.toLowerCase();
                              if (!lower.contains('card') &&
                                  !lower.contains('cc') &&
                                  !lower.contains('credit')) {
                                name = '$name Credit Card';
                              }
                              name = Account.formatDisplayName(name, ending);
                            } else if (_selectedType == 'Cash') {
                              final lower = name.toLowerCase();
                              if (!lower.contains('cash') &&
                                  !lower.contains('wallet')) {
                                name = '$name Cash';
                              }
                            }

                            await AppDatabase.instance.createAccount(
                              Account(
                                displayName: name,
                                institutionId:
                                    _institutionController.text.trim().isEmpty
                                    ? null
                                    : _institutionController.text.trim(),
                                accountType: switch (_selectedType) {
                                  'Bank' => AccountType.bankAccount,
                                  'Card' => AccountType.creditCard,
                                  'Wallet' => AccountType.wallet,
                                  _ => AccountType.cash,
                                },
                                lastFour:
                                    _cardEndingController.text.trim().isEmpty
                                    ? null
                                    : _cardEndingController.text.trim(),
                                upiHandle: _upiController.text.trim().isEmpty
                                    ? null
                                    : _upiController.text.trim(),
                                currentBalance: balance,
                              ),
                            );

                            if (context.mounted) {
                              Navigator.pop(context);
                              _loadAccounts();
                              AppToast.show(
                                context,
                                'Account added successfully',
                              );
                            }
                          } catch (e) {
                            if (context.mounted) {
                              AppToast.show(
                                context,
                                'Failed to add account: $e',
                                isError: true,
                              );
                            }
                          } finally {
                            setDialogState(() => _isSaving = false);
                          }
                        },
                  child: _isSaving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text('Add'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildTypeButton(
    String type,
    String label,
    StateSetter setDialogState,
  ) {
    final isSelected = _selectedType == type;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          setDialogState(() {
            _selectedType = type;
          });
        },
        child: Container(
          decoration: BoxDecoration(
            color: isSelected ? AppTheme.textDark : Colors.transparent,
            borderRadius: BorderRadius.circular(18),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              color: isSelected ? Colors.white : AppTheme.textMuted,
              fontWeight: FontWeight.bold,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 16),
                // Custom Header with Back Button
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: () => Navigator.pop(context),
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            border: Border.all(color: AppTheme.borderLight),
                            shape: BoxShape.circle,
                            color: Colors.white,
                          ),
                          child: const Icon(
                            Icons.arrow_back_ios_new_rounded,
                            size: 16,
                            color: AppTheme.textDark,
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Text(
                        'Accounts',
                        style: theme.textTheme.displayLarge?.copyWith(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.textDark,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // Accounts List
                Expanded(
                  child: _isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : _accounts.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.account_balance_rounded,
                                size: 64,
                                color: AppTheme.textMuted.withOpacity(0.4),
                              ),
                              const SizedBox(height: 16),
                              const Text(
                                'No accounts set up yet.',
                                style: TextStyle(
                                  color: AppTheme.textDark,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                            ],
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          itemCount: _accounts.length,
                          itemBuilder: (context, index) {
                            final acc = _accounts[index];
                            final isCard =
                                acc.accountType == AccountType.creditCard ||
                                acc.accountType == AccountType.debitCard;

                            return Container(
                              margin: const EdgeInsets.only(bottom: 16),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(20),
                                boxShadow: AppTheme.cardShadow,
                              ),
                              child: Material(
                                color: Colors.transparent,
                                borderRadius: BorderRadius.circular(20),
                                clipBehavior: Clip.antiAlias,
                                child: ListTile(
                                  contentPadding: const EdgeInsets.all(16),
                                  leading: ClipRRect(
                                    borderRadius: BorderRadius.circular(12),
                                    child: Image.asset(
                                      _getAccountIconPath(acc),
                                      width: 44,
                                      height: 44,
                                      fit: BoxFit.cover,
                                    ),
                                  ),
                                  title: Text(
                                    acc.bankName,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: AppTheme.textDark,
                                      fontSize: 16,
                                    ),
                                  ),
                                  subtitle: Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Text(
                                      _getAccountTypeLabel(acc),
                                      style: const TextStyle(
                                        color: AppTheme.textMuted,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                  trailing: Text(
                                    '₹ ${acc.currentBalance.toStringAsFixed(2)}',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: isCard && acc.currentBalance < 0
                                          ? AppTheme.errorRed
                                          : AppTheme.textDark,
                                      fontSize: 16,
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),

            // Floating "Add Account" Pill Button
            Positioned(
              bottom: 24,
              right: 24,
              child: GestureDetector(
                onTap: _showAddAccountDialog,
                child: Container(
                  height: 52,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  decoration: BoxDecoration(
                    color: AppTheme.primaryBlue,
                    borderRadius: BorderRadius.circular(26),
                    boxShadow: [
                      BoxShadow(
                        color: AppTheme.primaryBlue.withOpacity(0.3),
                        blurRadius: 12,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.add, color: Colors.white, size: 20),
                      SizedBox(width: 8),
                      Text(
                        'Add Account',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
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
    );
  }
}
