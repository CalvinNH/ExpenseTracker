import 'dart:convert';
import 'dart:io';

import 'package:expense_tracker/features/ingestion/notification_source_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final canonical = jsonDecode(
    File('assets/data/notification_sources_v1.json').readAsStringSync(),
  ) as Map<String, dynamic>;

  Set<String> canonicalSet(String name) =>
      (canonical[name] as List<dynamic>).cast<String>().toSet();

  Set<String> kotlinSet(String name) {
    final source = File(
      'android/app/src/main/kotlin/com/calvin/expense_tracker/'
      'NotificationCandidateEvaluator.kt',
    ).readAsStringSync();
    final body = RegExp(
      'val $name = setOf\\(([\\s\\S]*?)\\n    \\)',
    ).firstMatch(source)!.group(1)!;
    return RegExp('"([^"]+)"')
        .allMatches(body)
        .map((match) => match.group(1)!)
        .toSet();
  }

  test('canonical notification sources match Dart and native policy', () {
    final dartSets = <String, Set<String>>{
      'primaryFinancialPackages':
          NotificationSourcePolicy.knownFinancialPackages,
      'primaryWalletPackages': NotificationSourcePolicy.knownWalletPackages,
      'knownSmsPackages': NotificationSourcePolicy.knownSmsPackages,
      'bestEffortPackages':
          NotificationSourcePolicy.bestEffortEmailPackages,
      'corroborationOnlyPackages':
          NotificationSourcePolicy.knownMerchantPackages,
      'ignoredPackages': NotificationSourcePolicy.ignoredPackages,
    };

    for (final entry in dartSets.entries) {
      expect(entry.value, canonicalSet(entry.key), reason: 'Dart ${entry.key}');
      expect(kotlinSet(entry.key), canonicalSet(entry.key),
          reason: 'Kotlin ${entry.key}');
    }
  });

  test('institution packages are assigned to the correct source tier', () {
    final registry = jsonDecode(
      File('assets/data/institutions_v1.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final institutions = (registry['institutions'] as List<dynamic>)
        .cast<Map<String, dynamic>>();
    final merchantPackages = institutions
        .where((row) => row['institutionType'] == 'merchantPlatform')
        .expand((row) => (row['knownAndroidPackages'] as List<dynamic>))
        .cast<String>()
        .toSet();

    for (final institution in institutions) {
      final type = institution['institutionType'] as String;
      for (final packageName
          in (institution['knownAndroidPackages'] as List<dynamic>)
              .cast<String>()) {
        if (merchantPackages.contains(packageName)) {
          expect(canonicalSet('corroborationOnlyPackages'),
              contains(packageName));
        } else if (type == 'financialInstitution') {
          expect(canonicalSet('primaryFinancialPackages'),
              contains(packageName));
        } else if (type == 'paymentApplication' || type == 'wallet') {
          expect(canonicalSet('primaryWalletPackages'), contains(packageName));
        }
      }
    }
  });
}
