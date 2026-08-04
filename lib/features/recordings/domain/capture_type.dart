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
  // `asNameMap()`, not `byName()`: the latter throws on an unknown name, and an
  // unrecognised value is exactly the case this has to absorb.
  static CaptureType fromName(String? name) =>
      CaptureType.values.asNameMap()[name] ?? CaptureType.audioRecording;

  /// Whether the item has a playable media track. Guards `togglePlayback`,
  /// which is audio-only (`audioplayers`).
  bool get isPlayableAudio =>
      this == CaptureType.audioRecording || this == CaptureType.audioUpload;

  /// Whether a duration is meaningful for this type. Images and notes store
  /// `durationMs: 0`, and the card omits the segment rather than claiming a
  /// `00:00` runtime that no artifact actually has.
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

/// Inverse of [extensionFor]: which [CaptureType] a stray source file on disk
/// belongs to, or null when the extension is not one this app ever writes.
///
/// Used only by orphan recovery — re-adopting a source artifact whose index row
/// was lost. It is deliberately a *separate* function rather than a reverse
/// lookup of [_mimeExtensions], because that map is many-to-one (`audio/mp4`
/// and `audio/aac` both yield `m4a`) and because the answer wanted here is the
/// capture type, not the mime type it came from.
///
/// Null for anything unrecognised, which is what keeps `recordings.json`,
/// `logs.json`, `settings.json` and the `.thumb.jpg` posters out of the queue.
/// Extension matching is case-insensitive and tolerates a leading dot.
CaptureType? typeForExtension(String extension) {
  final String normalized = extension.trim().toLowerCase().replaceFirst(
    RegExp(r'^\.'),
    '',
  );
  return switch (normalized) {
    // Ambiguous by design: an `.m4a` is either a mic capture or an uploaded
    // AAC file, and nothing on disk distinguishes them once the index row is
    // gone. `audioRecording` is the same value `CaptureType.fromName(null)`
    // picks for a legacy row, so recovery degrades the way loading does.
    'm4a' => CaptureType.audioRecording,
    'mp3' || 'wav' || 'ogg' || 'flac' => CaptureType.audioUpload,
    'jpg' || 'jpeg' || 'png' || 'webp' || 'heic' => CaptureType.image,
    'mp4' || 'mov' => CaptureType.video,
    'txt' => CaptureType.text,
    _ => null,
  };
}
