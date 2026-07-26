import 'package:expense_tracker/app_shell.dart';
import 'package:expense_tracker/core/database/app_database.dart';
import 'package:expense_tracker/core/models/account.dart';
import 'package:expense_tracker/core/theme/app_theme.dart';
import 'package:expense_tracker/core/widgets/app_toast.dart';
import 'package:expense_tracker/features/ingestion/notification_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:notification_listener_service/notification_listener_service.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _formKey = GlobalKey<FormState>();
  final _entries = [
    _AccountEntry(nameHint: 'Cash Wallet')..selectedType = 'Cash',
  ];

  bool _isSaving = false;
  bool _isNotificationPermissionGranted = false;

  @override
  void initState() {
    super.initState();
    _checkPermissionStatus();
  }

  @override
  void dispose() {
    for (final entry in _entries) {
      entry.dispose();
    }
    super.dispose();
  }

  Future<void> _checkPermissionStatus() async {
    final granted = await NotificationListenerService.isPermissionGranted();
    if (mounted) {
      setState(() {
        _isNotificationPermissionGranted = granted;
      });
    }
  }

  void _addEntry() {
    setState(() => _entries.add(_AccountEntry(nameHint: 'Account name')));
  }

  void _removeEntry(int index) {
    if (_entries.length <= 1) {
      return;
    }
    setState(() {
      _entries.removeAt(index).dispose();
    });
  }

  Future<void> _saveAccounts() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    final accountsToSave = _entries.where((entry) {
      return entry.nameController.text.trim().isNotEmpty;
    }).toList();

    if (accountsToSave.isEmpty) {
      AppToast.show(
        context,
        'Add at least one account to continue',
        isError: true,
      );
      return;
    }

    setState(() => _isSaving = true);

    try {
      final db = AppDatabase.instance;

      for (final entry in accountsToSave) {
        String name = entry.nameController.text.trim();
        final balance =
            double.tryParse(entry.balanceController.text.trim()) ?? 0;

        if (entry.selectedType == 'Card') {
          final ending = entry.cardEndingController.text.trim();
          final lower = name.toLowerCase();
          if (!lower.contains('card') &&
              !lower.contains('cc') &&
              !lower.contains('credit')) {
            name = '$name Credit Card';
          }
          name = '$name ($ending)';
        } else if (entry.selectedType == 'Cash') {
          final lower = name.toLowerCase();
          if (!lower.contains('cash') && !lower.contains('wallet')) {
            name = '$name Cash';
          }
        }

        await db.createAccount(
          Account(bankName: name, currentBalance: balance),
        );
      }

      if (!mounted) {
        return;
      }

      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => const AppShell()),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }

      AppToast.show(context, 'Could not save accounts: $error', isError: true);
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _requestNotificationPermission() async {
    bool isGranted = await NotificationListenerService.isPermissionGranted();

    if (!isGranted) {
      isGranted = await NotificationListenerService.requestPermission();
    }

    if (isGranted) {
      await NotificationService.initialize();
    }

    if (mounted) {
      setState(() {
        _isNotificationPermissionGranted = isGranted;
      });
      AppToast.show(
        context,
        isGranted
            ? 'Permission Granted! Auto-tracking is active.'
            : 'Permission Denied. The app needs this to track expenses!',
        isError: !isGranted,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 24),
            children: [
              const SizedBox(height: 16),
              // Top logo and lock badge row
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Circular Brand Logo
                  Container(
                    width: 44,
                    height: 44,
                    decoration: const BoxDecoration(
                      color: AppTheme.primaryBlue,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.account_balance_wallet_rounded,
                      color: Colors.white,
                      size: 22,
                    ),
                  ),
                  // Lock Badge
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border.all(
                        color: AppTheme.primaryBlue.withOpacity(0.15),
                      ),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.lock_outline_rounded,
                          size: 14,
                          color: AppTheme.primaryBlue.withOpacity(0.8),
                        ),
                        const SizedBox(width: 6),
                        const Text(
                          'Private by design',
                          style: TextStyle(
                            color: AppTheme.primaryBlue,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 32),

              // Title Header
              Text(
                'Welcome to your\nprivate expense tracker',
                style: theme.textTheme.displayLarge?.copyWith(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.textDark,
                  height: 1.25,
                ),
              ),
              const SizedBox(height: 12),

              // Subtitle
              Text(
                'Your data stays on this device.\nNo accounts, no cloud, no tracking.',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: AppTheme.textMuted,
                  fontSize: 15,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 36),

              // Section Heading
              const Text(
                'Set up your accounts',
                style: TextStyle(
                  color: AppTheme.textDark,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 6),

              // Section Subtitle
              const Text(
                'Enter your current balances.\nYou can add more accounts anytime.',
                style: TextStyle(
                  color: AppTheme.textMuted,
                  fontSize: 14,
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 24),

              // Auto Tracking Permission Card
              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: AppTheme.cardShadow,
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: AppTheme.primaryBlue.withOpacity(0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      _isNotificationPermissionGranted
                          ? Icons.notifications_active_rounded
                          : Icons.notifications_none_rounded,
                      color: AppTheme.primaryBlue,
                      size: 20,
                    ),
                  ),
                  title: const Text(
                    'Enable Auto-Tracking',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: AppTheme.textDark,
                      fontSize: 14,
                    ),
                  ),
                  subtitle: const Text(
                    'Required to read bank SMS/Notifications',
                    style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
                  ),
                  trailing: TextButton(
                    onPressed: _requestNotificationPermission,
                    style: TextButton.styleFrom(
                      foregroundColor: _isNotificationPermissionGranted
                          ? AppTheme.successGreen
                          : AppTheme.primaryBlue,
                    ),
                    child: Text(
                      _isNotificationPermissionGranted ? 'ENABLED' : 'GRANT',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Accounts Card Container
              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: AppTheme.cardShadow,
                ),
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: _entries.length,
                      itemBuilder: (context, index) {
                        final entry = _entries[index];
                        final isLast = index == _entries.length - 1;
                        return Column(
                          children: [
                            _buildAccountInputForm(entry, index),
                            if (!isLast) const SizedBox(height: 24),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 20),
                    // Add account dashed/dotted-style outline button
                    GestureDetector(
                      onTap: _addEntry,
                      child: Container(
                        height: 52,
                        decoration: BoxDecoration(
                          color: AppTheme.primaryBlue.withOpacity(0.04),
                          border: Border.all(
                            color: AppTheme.primaryBlue.withOpacity(0.24),
                            style: BorderStyle.solid,
                          ),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.add,
                              color: AppTheme.primaryBlue,
                              size: 20,
                            ),
                            SizedBox(width: 8),
                            Text(
                              'Add another account',
                              style: TextStyle(
                                color: AppTheme.primaryBlue,
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),

              // Action Continue Button
              SizedBox(
                width: double.infinity,
                height: 54,
                child: FilledButton(
                  onPressed: _isSaving ? null : _saveAccounts,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.primaryBlue,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
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
                      : const Text(
                          'Continue',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 16),

              // Footer Text
              const Center(
                child: Text(
                  'You stay in control of your data',
                  style: TextStyle(
                    color: AppTheme.textMuted,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(height: 48),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAccountInputForm(_AccountEntry entry, int index) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Account ${index + 1}',
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                color: AppTheme.textDark,
                fontSize: 16,
              ),
            ),
            if (_entries.length > 1)
              GestureDetector(
                onTap: () => _removeEntry(index),
                child: const Text(
                  'Remove',
                  style: TextStyle(
                    color: AppTheme.errorRed,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        // Type Selector Row
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
              _buildTypeButton(entry, 'Bank', 'Bank'),
              _buildTypeButton(entry, 'Card', 'Credit Card'),
              _buildTypeButton(entry, 'Cash', 'Cash'),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (entry.selectedType == 'Card')
          Row(
            children: [
              Expanded(
                flex: 3,
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFFF9FAFB),
                    border: Border.all(
                      color: const Color(0xFFE5E7EB),
                      width: 1,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: TextFormField(
                    controller: entry.nameController,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: AppTheme.textDark,
                      fontSize: 16,
                    ),
                    decoration: InputDecoration(
                      labelText: 'Card name',
                      labelStyle: const TextStyle(
                        color: AppTheme.textMuted,
                        fontSize: 12,
                      ),
                      floatingLabelBehavior: FloatingLabelBehavior.always,
                      hintText: entry.nameHint,
                      hintStyle: const TextStyle(
                        color: Color(0xFF9CA3AF),
                        fontWeight: FontWeight.normal,
                      ),
                      border: InputBorder.none,
                    ),
                    textCapitalization: TextCapitalization.words,
                    validator: (value) {
                      final hasAnyName = entry.nameController.text
                          .trim()
                          .isNotEmpty;
                      final anyFilled =
                          entry.nameController.text.isNotEmpty ||
                          entry.balanceController.text.isNotEmpty ||
                          entry.cardEndingController.text.isNotEmpty;

                      if (!anyFilled) {
                        return null;
                      }

                      if (hasAnyName) {
                        return null;
                      }

                      return 'Enter name';
                    },
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFFF9FAFB),
                    border: Border.all(
                      color: const Color(0xFFE5E7EB),
                      width: 1,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: TextFormField(
                    controller: entry.cardEndingController,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: AppTheme.textDark,
                      fontSize: 16,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Last 4 digits',
                      labelStyle: TextStyle(
                        color: AppTheme.textMuted,
                        fontSize: 12,
                      ),
                      floatingLabelBehavior: FloatingLabelBehavior.always,
                      hintText: '1234',
                      hintStyle: TextStyle(
                        color: Color(0xFF9CA3AF),
                        fontWeight: FontWeight.normal,
                      ),
                      border: InputBorder.none,
                      counterText: '',
                    ),
                    keyboardType: TextInputType.number,
                    maxLength: 4,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    validator: (value) {
                      final text = value?.trim() ?? '';
                      final anyFilled =
                          entry.nameController.text.isNotEmpty ||
                          entry.balanceController.text.isNotEmpty ||
                          entry.cardEndingController.text.isNotEmpty;

                      if (!anyFilled) {
                        return null;
                      }

                      if (text.length != 4) {
                        return 'Need 4';
                      }

                      return null;
                    },
                  ),
                ),
              ),
            ],
          )
        else
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFFF9FAFB),
              border: Border.all(color: const Color(0xFFE5E7EB), width: 1),
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: TextFormField(
              controller: entry.nameController,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                color: AppTheme.textDark,
                fontSize: 16,
              ),
              decoration: InputDecoration(
                labelText: 'Account name',
                labelStyle: const TextStyle(
                  color: AppTheme.textMuted,
                  fontSize: 12,
                ),
                floatingLabelBehavior: FloatingLabelBehavior.always,
                hintText: entry.nameHint,
                hintStyle: const TextStyle(
                  color: Color(0xFF9CA3AF),
                  fontWeight: FontWeight.normal,
                ),
                border: InputBorder.none,
              ),
              textCapitalization: TextCapitalization.words,
              validator: (value) {
                final hasAnyName = entry.nameController.text.trim().isNotEmpty;
                final anyFilled =
                    entry.nameController.text.isNotEmpty ||
                    entry.balanceController.text.isNotEmpty;

                if (!anyFilled) {
                  return null;
                }

                if (hasAnyName) {
                  return null;
                }

                return 'Enter an account name';
              },
            ),
          ),
        const SizedBox(height: 12),
        // Custom Current Balance input
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFFF9FAFB),
            border: Border.all(color: const Color(0xFFE5E7EB), width: 1),
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: TextFormField(
            controller: entry.balanceController,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: AppTheme.textDark,
              fontSize: 16,
            ),
            decoration: const InputDecoration(
              labelText: 'Current balance',
              labelStyle: TextStyle(color: AppTheme.textMuted, fontSize: 12),
              floatingLabelBehavior: FloatingLabelBehavior.always,
              prefixText: '₹ ',
              prefixStyle: TextStyle(
                fontWeight: FontWeight.bold,
                color: AppTheme.textDark,
                fontSize: 16,
              ),
              hintText: '0.00',
              hintStyle: TextStyle(
                color: Color(0xFF9CA3AF),
                fontWeight: FontWeight.normal,
              ),
              border: InputBorder.none,
            ),
            keyboardType: const TextInputType.numberWithOptions(
              decimal: true,
              signed: true,
            ),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'^-?\d*\.?\d{0,2}')),
            ],
            validator: (value) {
              final text = value?.trim() ?? '';
              if (text.isEmpty) {
                return null;
              }

              if (double.tryParse(text) == null) {
                return 'Enter a valid amount';
              }

              return null;
            },
          ),
        ),
      ],
    );
  }

  Widget _buildTypeButton(_AccountEntry entry, String type, String label) {
    final isSelected = entry.selectedType == type;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() {
            entry.selectedType = type;
            if (type == 'Bank') {
              entry.nameHint = 'e.g. HDFC Savings';
            } else if (type == 'Card') {
              entry.nameHint = 'e.g. ICICI Credit Card';
            } else {
              entry.nameHint = 'e.g. Cash Wallet';
            }
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
}

class _AccountEntry {
  _AccountEntry({this.nameHint = 'Account name'});

  String nameHint;
  String selectedType = 'Bank'; // 'Bank', 'Card', 'Cash'
  final nameController = TextEditingController();
  final balanceController = TextEditingController();
  final cardEndingController = TextEditingController();

  void dispose() {
    nameController.dispose();
    balanceController.dispose();
    cardEndingController.dispose();
  }
}
