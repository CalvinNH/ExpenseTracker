enum NotificationSourceClass {
  defaultSmsPackage,
  knownFinancialPackage,
  knownWalletPackage,
  knownMerchantPackage,
  ignoredPackage,
  unknownPackage,
}

/// Offline-only package knowledge used as a signal, never as a universal
/// allowlist. Unknown packages remain eligible for retention and parsing.
class NotificationSourcePolicy {
  NotificationSourcePolicy({this.defaultSmsPackage});

  final String? defaultSmsPackage;

  static const knownFinancialPackages = <String>{
    'com.snapwork.hdfc',
    'com.sbi.SBIFreedomPlus',
    'com.csam.icici.bank.imobile',
    'com.axis.mobile',
    'com.msf.kbank.mobile',
    'com.kotakbank.mobile',
    'com.idfcfirstbank.optimus',
    'com.yesbank',
    'com.indusind.indusmobile',
    'com.rblbank.mobank',
  };

  static const knownWalletPackages = <String>{
    'net.one97.paytm',
    'com.google.android.apps.nbu.paisa.user',
    'com.phonepe.app',
    'in.org.npci.upiapp',
    'com.mobikwik_new',
    'com.freecharge.android',
  };

  static const knownMerchantPackages = <String>{
    'in.amazon.mShop.android.shopping',
    'com.flipkart.android',
    'com.application.zomato',
    'in.swiggy.android',
    'com.ubercab',
    'com.olacabs.customer',
    'com.myntra.android',
  };

  static const ignoredPackages = <String>{
    'com.calvin.expense_tracker',
    'android',
    'com.android.systemui',
    'com.google.android.gms',
    'com.android.vending',
  };

  static const knownSmsPackages = <String>{
    'com.google.android.apps.messaging',
    'com.samsung.android.messaging',
    'com.android.mms',
    'com.miui.mms',
    'com.oneplus.mms',
  };

  NotificationSourceClass classify(String packageName) {
    if (ignoredPackages.contains(packageName)) {
      return NotificationSourceClass.ignoredPackage;
    }
    if (defaultSmsPackage != null && packageName == defaultSmsPackage) {
      return NotificationSourceClass.defaultSmsPackage;
    }
    // When Android cannot report the current default, locally known SMS apps
    // receive the same source treatment. This is classification, not filtering.
    if (knownSmsPackages.contains(packageName)) {
      return NotificationSourceClass.defaultSmsPackage;
    }
    if (knownFinancialPackages.contains(packageName)) {
      return NotificationSourceClass.knownFinancialPackage;
    }
    if (knownWalletPackages.contains(packageName)) {
      return NotificationSourceClass.knownWalletPackage;
    }
    if (knownMerchantPackages.contains(packageName)) {
      return NotificationSourceClass.knownMerchantPackage;
    }
    return NotificationSourceClass.unknownPackage;
  }
}
