import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

enum InstitutionType {
  financialInstitution,
  paymentApplication,
  wallet,
  merchantPlatform;

  static InstitutionType parse(String value) =>
      values.firstWhere((candidate) => candidate.name == value);
}

class InstitutionRecord {
  const InstitutionRecord({
    required this.institutionId,
    required this.canonicalName,
    required this.institutionType,
    required this.aliases,
    required this.knownAndroidPackages,
    required this.ifscPrefixes,
    required this.titlePatterns,
    required this.senderPatterns,
  });

  final String institutionId;
  final String canonicalName;
  final InstitutionType institutionType;
  final List<String> aliases;
  final List<String> knownAndroidPackages;
  final List<String> ifscPrefixes;
  final List<String> titlePatterns;
  final List<String> senderPatterns;

  factory InstitutionRecord.fromJson(Map<String, Object?> json) {
    List<String> strings(String key) =>
        (json[key] as List<Object?>? ?? const []).cast<String>();
    return InstitutionRecord(
      institutionId: json['institutionId']! as String,
      canonicalName: json['canonicalName']! as String,
      institutionType: InstitutionType.parse(
        json['institutionType']! as String,
      ),
      aliases: strings('aliases'),
      knownAndroidPackages: strings('knownAndroidPackages'),
      ifscPrefixes: strings('ifscPrefixes'),
      titlePatterns: strings('titlePatterns'),
      senderPatterns: strings('senderPatterns'),
    );
  }
}

class InstitutionRegistry {
  const InstitutionRegistry({
    required this.schemaVersion,
    required this.registryVersion,
    required this.institutions,
  });

  final int schemaVersion;
  final String registryVersion;
  final List<InstitutionRecord> institutions;

  static Future<InstitutionRegistry> load({
    AssetBundle? bundle,
    String assetPath = 'assets/data/institutions_v1.json',
  }) async {
    WidgetsFlutterBinding.ensureInitialized();
    return InstitutionRegistry.fromJson(
      await (bundle ?? rootBundle).loadString(assetPath),
    );
  }

  factory InstitutionRegistry.fromJson(String source) {
    final json = jsonDecode(source) as Map<String, Object?>;
    return InstitutionRegistry(
      schemaVersion: json['schemaVersion']! as int,
      registryVersion: json['registryVersion']! as String,
      institutions: (json['institutions']! as List<Object?>)
          .cast<Map<String, Object?>>()
          .map(InstitutionRecord.fromJson)
          .toList(growable: false),
    );
  }

  InstitutionRecord? byId(String? id) {
    if (id == null) return null;
    final normalized = _normalize(id);
    for (final record in institutions) {
      if (_normalize(record.institutionId) == normalized ||
          record.aliases.any((alias) => _normalize(alias) == normalized) ||
          _normalize(record.canonicalName) == normalized) {
        return record;
      }
    }
    return null;
  }

  List<InstitutionRecord> byPackage(String packageName) => institutions
      .where(
        (record) => record.knownAndroidPackages.any(
          (value) => value.toLowerCase() == packageName.toLowerCase(),
        ),
      )
      .toList(growable: false);

  static String normalize(String value) => _normalize(value);
}

String _normalize(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
