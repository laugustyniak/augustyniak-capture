enum RecordingTagSource {
  ai,
  human;

  static RecordingTagSource fromName(String? value) =>
      RecordingTagSource.values.where((RecordingTagSource item) {
        return item.name == value;
      }).firstOrNull ??
      RecordingTagSource.human;
}

/// A normalized tag together with the actor that owns it.
class RecordingTag {
  const RecordingTag({required this.value, required this.source});

  final String value;
  final RecordingTagSource source;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'value': value,
    'source': source.name,
  };

  static RecordingTag? fromJson(dynamic json) {
    // Legacy strings have unknowable provenance. Human is conservative: a
    // wrong color is recoverable, overwriting a person's tag is not.
    if (json is String) {
      final String value = normalizeValue(json);
      return value.isEmpty
          ? null
          : RecordingTag(value: value, source: RecordingTagSource.human);
    }
    if (json is! Map<String, dynamic>) return null;
    final Object? rawValue = json['value'];
    if (rawValue is! String) return null;
    final String value = normalizeValue(rawValue);
    if (value.isEmpty) return null;
    return RecordingTag(
      value: value,
      source: RecordingTagSource.fromName(
        json['source'] is String ? json['source'] as String : null,
      ),
    );
  }

  static String normalizeValue(String value) => value.trim().toLowerCase();

  static List<RecordingTag> normalize(Iterable<RecordingTag> tags) {
    final Set<String> seen = <String>{};
    final List<RecordingTag> normalized = <RecordingTag>[];
    final List<RecordingTag> ordered = <RecordingTag>[
      ...tags.where(
        (RecordingTag tag) => tag.source == RecordingTagSource.human,
      ),
      ...tags.where((RecordingTag tag) => tag.source == RecordingTagSource.ai),
    ];
    for (final RecordingTag tag in ordered) {
      final String value = normalizeValue(tag.value);
      if (value.isEmpty || !seen.add(value)) continue;
      normalized.add(RecordingTag(value: value, source: tag.source));
    }
    return List<RecordingTag>.unmodifiable(normalized);
  }

  @override
  bool operator ==(Object other) =>
      other is RecordingTag && other.value == value && other.source == source;

  @override
  int get hashCode => Object.hash(value, source);
}
