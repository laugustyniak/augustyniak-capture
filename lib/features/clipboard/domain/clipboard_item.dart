import 'package:flutter/foundation.dart';

enum ClipboardItemType {
  text,
  image;

  static ClipboardItemType fromName(String? name) {
    return ClipboardItemType.values.firstWhere(
      (e) => e.name == name,
      orElse: () => ClipboardItemType.text,
    );
  }
}

@immutable
class ClipboardItem {
  const ClipboardItem({
    required this.id,
    required this.type,
    required this.copiedAt,
    this.text,
    this.imagePath,
    this.preview,
  });

  final String id;
  final ClipboardItemType type;
  final DateTime copiedAt;
  final String? text;
  final String? imagePath;
  final String? preview;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'type': type.name,
        'copiedAt': copiedAt.toIso8601String(),
        if (text != null) 'text': text,
        if (imagePath != null) 'imagePath': imagePath,
        if (preview != null) 'preview': preview,
      };

  factory ClipboardItem.fromJson(Map<String, dynamic> json) {
    return ClipboardItem(
      id: json['id'] as String,
      type: ClipboardItemType.fromName(json['type'] as String?),
      copiedAt: DateTime.parse(json['copiedAt'] as String),
      text: json['text'] as String?,
      imagePath: json['imagePath'] as String?,
      preview: json['preview'] as String?,
    );
  }

  ClipboardItem copyWith({
    String? id,
    ClipboardItemType? type,
    DateTime? copiedAt,
    String? text,
    String? imagePath,
    String? preview,
  }) {
    return ClipboardItem(
      id: id ?? this.id,
      type: type ?? this.type,
      copiedAt: copiedAt ?? this.copiedAt,
      text: text ?? this.text,
      imagePath: imagePath ?? this.imagePath,
      preview: preview ?? this.preview,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ClipboardItem &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          type == other.type &&
          copiedAt == other.copiedAt &&
          text == other.text &&
          imagePath == other.imagePath &&
          preview == other.preview;

  @override
  int get hashCode => Object.hash(id, type, copiedAt, text, imagePath, preview);
}
