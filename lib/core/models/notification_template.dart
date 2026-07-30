class NotificationTemplate {
  const NotificationTemplate({
    this.id,
    required this.fingerprint,
    required this.sourcePackage,
    required this.observedCount,
    required this.successfulParseCount,
    required this.conflictingParseCount,
    required this.lastObserved,
    required this.fieldPositionMetadata,
    required this.isPromoted,
    required this.roleSignature,
  });

  final int? id;
  final String fingerprint;
  final String sourcePackage;
  final int observedCount;
  final int successfulParseCount;
  final int conflictingParseCount;
  final DateTime lastObserved;
  final String fieldPositionMetadata;
  final bool isPromoted;
  final String roleSignature;

  Map<String, Object?> toMap() => {
    if (id != null) 'id': id,
    'fingerprint': fingerprint,
    'source_package': sourcePackage,
    'observed_count': observedCount,
    'successful_parse_count': successfulParseCount,
    'conflicting_parse_count': conflictingParseCount,
    'last_observed': lastObserved.toUtc().toIso8601String(),
    'field_position_metadata': fieldPositionMetadata,
    'is_promoted': isPromoted ? 1 : 0,
    'role_signature': roleSignature,
  };

  factory NotificationTemplate.fromMap(Map<String, Object?> map) => NotificationTemplate(
    id: map['id'] as int?,
    fingerprint: map['fingerprint'] as String,
    sourcePackage: map['source_package'] as String,
    observedCount: map['observed_count'] as int,
    successfulParseCount: map['successful_parse_count'] as int,
    conflictingParseCount: map['conflicting_parse_count'] as int,
    lastObserved: DateTime.parse(map['last_observed'] as String),
    fieldPositionMetadata: map['field_position_metadata'] as String,
    isPromoted: (map['is_promoted'] as int) == 1,
    roleSignature: map['role_signature'] as String,
  );
}
