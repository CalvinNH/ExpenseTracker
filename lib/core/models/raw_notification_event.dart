import 'package:expense_tracker/core/models/financial_enums.dart';

class RawNotificationEvent {
  const RawNotificationEvent({
    this.id,
    required this.packageName,
    this.notificationKey,
    this.notificationId,
    this.notificationTag,
    this.title,
    this.content,
    required this.postedAt,
    required this.ingestedAt,
    required this.payloadHash,
    required this.parserVersion,
    required this.processingState,
    this.structuralFingerprint,
  });

  final int? id;
  final String packageName;
  final String? notificationKey;
  final int? notificationId;
  final String? notificationTag;
  final String? title;
  final String? content;
  final DateTime postedAt;
  final DateTime ingestedAt;
  final String payloadHash;
  final int parserVersion;
  final RawNotificationProcessingState processingState;
  final String? structuralFingerprint;

  Map<String, Object?> toMap() => {
    if (id != null) 'id': id,
    'package_name': packageName,
    'notification_key': notificationKey,
    'notification_id': notificationId,
    'notification_tag': notificationTag,
    'title': title,
    'content': content,
    'posted_at': postedAt.toIso8601String(),
    'ingested_at': ingestedAt.toIso8601String(),
    'payload_hash': payloadHash,
    'parser_version': parserVersion,
    'processing_state': processingState.storageValue,
    'structural_fingerprint': structuralFingerprint,
  };

  factory RawNotificationEvent.fromMap(Map<String, Object?> map) {
    return RawNotificationEvent(
      id: map['id'] as int?,
      packageName: map['package_name'] as String,
      notificationKey: map['notification_key'] as String?,
      notificationId: map['notification_id'] as int?,
      notificationTag: map['notification_tag'] as String?,
      title: map['title'] as String?,
      content: map['content'] as String?,
      postedAt: DateTime.parse(map['posted_at'] as String),
      ingestedAt: DateTime.parse(map['ingested_at'] as String),
      payloadHash: map['payload_hash'] as String,
      parserVersion: map['parser_version'] as int,
      processingState: RawNotificationProcessingState.fromStorage(
        map['processing_state'] as String,
      ),
      structuralFingerprint: map['structural_fingerprint'] as String?,
    );
  }
}
