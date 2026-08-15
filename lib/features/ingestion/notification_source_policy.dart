enum NotificationSourceClass {
  defaultSmsPackage,
  knownNonDefaultSmsPackage,
  knownFinancialPackage,
  knownWalletPackage,
  knownMerchantPackage,
  bestEffortEmailPackage,
  ignoredPackage,
  unknownPackage,
}

/// Offline-only package knowledge used as a signal, never as a universal
/// allowlist. Unknown packages remain eligible for retention and parsing.
class NotificationSourcePolicy {
  NotificationSourcePolicy({this.defaultSmsPackage});

  final String? defaultSmsPackage;

  static const knownFinancialPackages = <String>{
    'com.sbi.lotusintouch',
    'com.snapwork.hdfc',
    'com.sbi.SBIFreedomPlus',
    'com.csam.icici.bank.imobile',
    'com.axis.mobile',
    'com.msf.kbank.mobile',
    'com.kotakbank.mobile',
    'com.Version1',
    'com.bankofbaroda.mconnect',
    'com.canarabank.mobility',
    'com.infrasoft.uboi',
    'com.IndianBank.IndOASIS',
    'com.idfcfirstbank.optimus',
    'com.atomyes',
    'com.yesbank',
    'com.fss.indus',
    'com.indusind.indusmobile',
    'com.fedmobile',
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

  static const bestEffortEmailPackages = <String>{'com.google.android.gm'};

  static const ignoredPackages = <String>{
    'com.calvin.expense_tracker',
    'android',
    'com.android.systemui',
    'com.google.android.gms',
    'com.android.vending',
    'com.spotify.music',
    'com.google.android.apps.youtube.music',
    'com.google.android.youtube',
    'com.amazon.mp3',
    'com.apple.android.music',
    'org.videolan.vlc',
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
    final reportedDefault = defaultSmsPackage?.trim();
    final hasReportedDefault = reportedDefault?.isNotEmpty ?? false;
    if (hasReportedDefault && packageName == reportedDefault) {
      return NotificationSourceClass.defaultSmsPackage;
    }
    if (knownSmsPackages.contains(packageName)) {
      return NotificationSourceClass.knownNonDefaultSmsPackage;
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
    if (bestEffortEmailPackages.contains(packageName)) {
      return NotificationSourceClass.bestEffortEmailPackage;
    }
    return NotificationSourceClass.unknownPackage;
  }
}
