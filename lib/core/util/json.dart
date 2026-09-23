/// Tolerant JSON accessors: the API contract is still being finalised, so
/// parsing must not crash on a missing optional field.
typedef Json = Map<String, dynamic>;

extension JsonX on Map<String, dynamic> {
  String str(String key, [String fallback = '']) {
    final v = this[key];
    return v == null ? fallback : v.toString();
  }

  String? strOrNull(String key) => this[key]?.toString();

  int intOr(String key, [int fallback = 0]) {
    final v = this[key];
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? fallback;
  }

  bool boolOr(String key, [bool fallback = false]) {
    final v = this[key];
    return v is bool ? v : fallback;
  }

  DateTime? date(String key) {
    final v = this[key];
    return v == null ? null : DateTime.tryParse(v.toString());
  }

  List<Json> list(String key) {
    final v = this[key];
    if (v is List) return v.whereType<Map<String, dynamic>>().toList();
    return const [];
  }

  Json obj(String key) {
    final v = this[key];
    return v is Map<String, dynamic> ? v : <String, dynamic>{};
  }
}
