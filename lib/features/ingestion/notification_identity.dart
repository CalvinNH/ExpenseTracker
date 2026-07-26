import 'dart:convert';

class NotificationIdentity {
  NotificationIdentity._();

  /// Deterministic FNV-1a 64-bit hash over stable plugin fields. This avoids
  /// platform-randomized String.hashCode and requires no network dependency.
  static String payloadHash({
    required String packageName,
    String? title,
    String? content,
  }) {
    final bytes = utf8.encode(
      '$packageName\u001f${title ?? ''}\u001f${content ?? ''}',
    );
    var hash = BigInt.parse('14695981039346656037');
    final prime = BigInt.from(1099511628211);
    final mask = BigInt.parse('18446744073709551615');
    for (final byte in bytes) {
      hash ^= BigInt.from(byte);
      hash = (hash * prime) & mask;
    }
    return 'fnv1a64:${hash.toRadixString(16).padLeft(16, '0')}';
  }

  static String structuralFingerprint(String? title, String? content) {
    final normalized = '${title ?? ''} ${content ?? ''}'
        .toLowerCase()
        .replaceAll(RegExp(r'\d+'), '#')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return payloadHash(packageName: 'structure', content: normalized);
  }
}
