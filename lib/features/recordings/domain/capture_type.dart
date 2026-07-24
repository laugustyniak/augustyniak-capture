/// What kind of source artifact a queue item holds.
///
/// Every value shares the same durability rule: the source file is written and
/// verified before the item is indexed, and processing never mutates or deletes
/// it. Only the processor and the card presentation differ per type.
enum CaptureType {
  /// Microphone capture, `.m4a` — the Phase-1 default and the legacy value for
  /// rows written before this field existed.
  audioRecording,

  /// Audio file picked by the user; keeps its original extension so it plays back.
  audioUpload,

  /// Photo or picked image, `.jpg`/`.png`.
  image,

  /// Typed note. The body itself is the source artifact, stored as `.txt`.
  text,

  /// Captured or picked video, `.mp4`/`.mov`.
  video;

  /// Legacy/forward-compatible defaulting point: `null` (old JSON) and any
  /// unknown name (JSON from a newer build) both restore as [audioRecording],
  /// mirroring how `LogEvent` degrades an unknown level to `info`.
  static CaptureType fromName(String? name) {
    for (final CaptureType type in CaptureType.values) {
      if (type.name == name) return type;
    }
    return CaptureType.audioRecording;
  }

  bool get isAudio =>
      this == CaptureType.audioRecording || this == CaptureType.audioUpload;

  /// Whether the item has a playable media track. Guards `togglePlayback`,
  /// which is audio-only (`audioplayers`).
  bool get isPlayableAudio => isAudio;

  /// Items with no media track render no duration — `durationMs` is `0` for
  /// these and `00:00` would be noise.
  bool get hasDuration => this != CaptureType.image && this != CaptureType.text;
}

/// Storage extension policy: `<uuid>.<extensionFor(type)>` in the recordings
/// directory.
///
/// Mic captures stay `m4a` because the encoder and container are fixed. Uploads
/// derive their extension from the mime type recorded at ingestion so the file
/// still opens and plays; an unknown mime falls back to the per-type default
/// rather than inventing an extension.
String extensionFor(CaptureType type, {String? mimeType}) {
  return switch (type) {
    CaptureType.audioRecording => 'm4a',
    CaptureType.text => 'txt',
    CaptureType.audioUpload => _fromMime(mimeType, fallback: 'm4a'),
    CaptureType.image => _fromMime(mimeType, fallback: 'jpg'),
    CaptureType.video => _fromMime(mimeType, fallback: 'mp4'),
  };
}

/// Deliberately small: only what the pickers actually hand back.
const Map<String, String> _mimeExtensions = <String, String>{
  'audio/mpeg': 'mp3',
  'audio/mp4': 'm4a',
  'audio/aac': 'm4a',
  'audio/wav': 'wav',
  'audio/x-wav': 'wav',
  'audio/ogg': 'ogg',
  'audio/flac': 'flac',
  'image/jpeg': 'jpg',
  'image/png': 'png',
  'image/webp': 'webp',
  'image/heic': 'heic',
  'video/mp4': 'mp4',
  'video/quicktime': 'mov',
  'text/plain': 'txt',
};

String _fromMime(String? mimeType, {required String fallback}) {
  if (mimeType == null) return fallback;
  return _mimeExtensions[mimeType.trim().toLowerCase()] ?? fallback;
}
