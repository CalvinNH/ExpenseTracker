import 'dart:convert';

enum NotificationTemplateFieldType {
  amount,
  account,
  card,
  date,
  time,
  reference,
  vpa,
  merchant;

  String get placeholder => '<${name.toUpperCase()}>';

  static NotificationTemplateFieldType fromPlaceholder(String value) {
    return values.firstWhere(
      (type) => type.placeholder == value,
      orElse: () => throw const FormatException(
        'Unknown notification-template field type.',
      ),
    );
  }
}

class NotificationTemplateFieldPosition {
  const NotificationTemplateFieldPosition({
    required this.type,
    required this.tokenIndex,
  });

  final NotificationTemplateFieldType type;
  final int tokenIndex;

  Map<String, Object?> toJson() => {
    'type': type.placeholder,
    'token': tokenIndex,
  };

  factory NotificationTemplateFieldPosition.fromJson(
    Map<String, Object?> json,
  ) {
    if (json.length != 2 ||
        !json.containsKey('type') ||
        !json.containsKey('token') ||
        json['type'] is! String ||
        json['token'] is! int) {
      throw const FormatException(
        'Invalid notification-template field position.',
      );
    }
    final tokenIndex = json['token']! as int;
    if (tokenIndex < 0) {
      throw const FormatException(
        'Notification-template token indexes cannot be negative.',
      );
    }
    return NotificationTemplateFieldPosition(
      type: NotificationTemplateFieldType.fromPlaceholder(
        json['type']! as String,
      ),
      tokenIndex: tokenIndex,
    );
  }
}

/// Strict, value-free metadata. This is serialized data only; it is never
/// interpreted as Dart, JavaScript, SQL, or a regular expression.
class NotificationTemplateFieldMetadata {
  NotificationTemplateFieldMetadata({
    required List<NotificationTemplateFieldPosition> fields,
  }) : fields = List.unmodifiable(fields) {
    if (fields.length > 16) {
      throw const FormatException(
        'Notification-template metadata cannot contain more than 16 fields.',
      );
    }
    var previousToken = -1;
    for (final field in fields) {
      if (field.tokenIndex < previousToken) {
        throw const FormatException(
          'Notification-template token indexes must be nondecreasing.',
        );
      }
      previousToken = field.tokenIndex;
    }
  }

  static const version = 1;

  final List<NotificationTemplateFieldPosition> fields;

  Map<String, Object?> toJson() => {
    'version': version,
    'fields': fields.map((field) => field.toJson()).toList(growable: false),
  };

  String get canonicalJson => jsonEncode(toJson());

  factory NotificationTemplateFieldMetadata.fromJsonString(String value) {
    final Object? decoded;
    try {
      decoded = jsonDecode(value);
    } on FormatException {
      throw const FormatException(
        'Invalid notification-template metadata JSON.',
      );
    }
    if (decoded is! Map<String, Object?> ||
        decoded.length != 2 ||
        decoded['version'] != version ||
        decoded['fields'] is! List<Object?>) {
      throw const FormatException('Invalid notification-template metadata.');
    }
    final fields = (decoded['fields']! as List<Object?>)
        .map((field) {
          if (field is! Map<String, Object?>) {
            throw const FormatException(
              'Invalid notification-template field metadata.',
            );
          }
          return NotificationTemplateFieldPosition.fromJson(field);
        })
        .toList(growable: false);
    return NotificationTemplateFieldMetadata(fields: fields);
  }
}

enum NotificationTemplatePromotionStatus {
  learning,
  promoted,
  blocked;

  String get storageValue => name;

  static NotificationTemplatePromotionStatus fromStorage(String value) {
    return values.firstWhere(
      (status) => status.storageValue == value,
      orElse: () => throw const FormatException(
        'Unknown notification-template promotion status.',
      ),
    );
  }
}

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
    required this.promotionStatus,
    required this.roleSignature,
  });

  static const minimumObservationsForPromotion = 3;

  final int? id;
  final String fingerprint;
  final String sourcePackage;
  final int observedCount;
  final int successfulParseCount;
  final int conflictingParseCount;
  final DateTime lastObserved;
  final NotificationTemplateFieldMetadata fieldPositionMetadata;
  final NotificationTemplatePromotionStatus promotionStatus;
  final String roleSignature;

  bool get isPromoted =>
      promotionStatus == NotificationTemplatePromotionStatus.promoted;

  Map<String, Object?> toMap() => {
    if (id != null) 'id': id,
    'fingerprint': fingerprint,
    'source_package': sourcePackage,
    'observed_count': observedCount,
    'successful_parse_count': successfulParseCount,
    'conflicting_parse_count': conflictingParseCount,
    'last_observed': lastObserved.toUtc().toIso8601String(),
    'field_position_metadata': fieldPositionMetadata.canonicalJson,
    'promotion_status': promotionStatus.storageValue,
    'role_signature': roleSignature,
  };

  factory NotificationTemplate.fromMap(Map<String, Object?> map) =>
      NotificationTemplate(
        id: map['id'] as int?,
        fingerprint: map['fingerprint'] as String,
        sourcePackage: map['source_package'] as String,
        observedCount: map['observed_count'] as int,
        successfulParseCount: map['successful_parse_count'] as int,
        conflictingParseCount: map['conflicting_parse_count'] as int,
        lastObserved: DateTime.parse(map['last_observed'] as String),
        fieldPositionMetadata: NotificationTemplateFieldMetadata.fromJsonString(
          map['field_position_metadata'] as String,
        ),
        promotionStatus: NotificationTemplatePromotionStatus.fromStorage(
          map['promotion_status'] as String,
        ),
        roleSignature: map['role_signature'] as String,
      );
}
