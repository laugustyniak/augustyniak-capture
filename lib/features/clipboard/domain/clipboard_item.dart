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
    this.collections = const <String>{},
  });

  final String id;
  final ClipboardItemType type;
  final DateTime copiedAt;
  final String? text;
  final String? imagePath;
  final String? preview;
  final Set<String> collections;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'type': type.name,
        'copiedAt': copiedAt.toIso8601String(),
        if (text != null) 'text': text,
        if (imagePath != null) 'imagePath': imagePath,
        if (preview != null) 'preview': preview,
        if (collections.isNotEmpty) 'collections': collections.toList(),
      };

  factory ClipboardItem.fromJson(Map<String, dynamic> json) {
    final dynamic rawCollections = json['collections'];
    final Set<String> parsedCollections = rawCollections is List
        ? rawCollections.map((e) => e.toString()).toSet()
        : const <String>{};

    return ClipboardItem(
      id: json['id'] as String,
      type: ClipboardItemType.fromName(json['type'] as String?),
      copiedAt: DateTime.parse(json['copiedAt'] as String),
      text: json['text'] as String?,
      imagePath: json['imagePath'] as String?,
      preview: json['preview'] as String?,
      collections: parsedCollections,
    );
  }

  ClipboardItem copyWith({
    String? id,
    ClipboardItemType? type,
    DateTime? copiedAt,
    String? text,
    String? imagePath,
    String? preview,
    Set<String>? collections,
  }) {
    return ClipboardItem(
      id: id ?? this.id,
      type: type ?? this.type,
      copiedAt: copiedAt ?? this.copiedAt,
      text: text ?? this.text,
      imagePath: imagePath ?? this.imagePath,
      preview: preview ?? this.preview,
      collections: collections ?? this.collections,
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
          preview == other.preview &&
          setEquals(collections, other.collections);

  @override
  int get hashCode => Object.hash(
        id,
        type,
        copiedAt,
        text,
        imagePath,
        preview,
        Object.hashAllUnordered(collections),
      );
}
