import 'agent_artifact.dart';
import 'capture_category.dart';
import 'capture_type.dart';
import 'route_record.dart';
import 'recording_tag.dart';

/// Generic processing state, not transcription-specific: `pendingTranscription`
/// and `transcribing` mean "queued" and "running" for whichever processor the
/// item's [CaptureType] resolves to (transcription, OCR, text passthrough).
/// The names are kept because renaming ripples through persisted JSON.
enum RecordingStatus {
  saved,
  pendingTranscription,
  transcribing,
  completed,
  failed,
}

/// One item in the queue. Despite the name this covers every [CaptureType] —
/// mic recordings, uploads, images, text notes and video — because they share
/// every field and the whole persistence stack is keyed on one list type.
class Recording {
  static final RegExp _sha256 = RegExp(r'^[0-9a-f]{64}$');

  const Recording({
    required this.id,
    required this.filePath,
    required this.createdAt,
    required this.durationMs,
    required this.status,
    this.sizeBytes = 0,
    this.contentHash,
    this.type = CaptureType.audioRecording,
    this.sourceMimeType,
    this.transcript,
    this.thumbPath,
    this.title,
    this.category,
    this.summary,
    this.tags = const <String>[],
    this.projectId,
    this.error,
    this.isProcessedByUser = false,
    this.processedAt,
    this.routes = const <RouteRecord>[],
    this.artifacts = const <AgentArtifact>[],
  });

  final String id;
  final String filePath;
  final DateTime createdAt;

  /// Length of the media track; `0` for images and text notes, which the UI
  /// suppresses rather than rendering `00:00`.
  final int durationMs;
  final RecordingStatus status;

  /// Size of the source artifact, measured during the same `length()` check
  /// that verifies the file is non-empty at capture time. `0` on legacy rows,
  /// where the card simply omits the size from its verification footer.
  final int sizeBytes;

  /// Lowercase hexadecimal SHA-256 of the immutable source artifact.
  ///
  /// Null means it has not been computed yet, which is valid for legacy rows
  /// and for a source that was unavailable when the best-effort backfill ran.
  /// This is an attribute used for cross-device duplicate detection; [id]
  /// remains the capture's identity and two rows may legitimately share it.
  final String? contentHash;

  /// Immutable identity, set at construction and never changed by the pipeline.
  final CaptureType type;

  /// Recorded at ingestion so uploads keep their identity (`image/png`,
  /// `audio/mpeg`). Null on legacy rows and on mic captures.
  final String? sourceMimeType;

  /// Processor output text: transcript, OCR result, or the note body. Nullable
  /// until processing completes; this is what the Queue search matches on.
  /// User-editable after processing (never touched by the pipeline once set by
  /// the user — edits and re-processing are distinct paths).
  final String? transcript;

  /// Path to a poster frame extracted from a video source. **Derived**, never
  /// the source: it is generated after the item is already persisted, it plays
  /// no part in the persist-before-process guarantee, and it is safe to lose —
  /// a missing or deleted poster costs a thumbnail, never a capture. Null on
  /// every non-video item, on legacy rows, and whenever the extraction failed.
  final String? thumbPath;

  /// Optional display name, set by the user or by the enrichment stage. Null on
  /// legacy rows and until named, in which case the UI names the item by type
  /// and time (`displayNameFor`) rather than by its uuid filename. Never set by
  /// processing.
  final String? title;

  /// What the item *is*, assigned by the enrichment stage and correctable by
  /// the user.
  ///
  /// **Null and [CaptureCategory.capture] are different states.** Null means
  /// enrichment never ran — no profile configured, or the call failed.
  /// `capture` means it ran and could not place the item. Collapsing them would
  /// make an unconfigured install indistinguishable from a failing model.
  final CaptureCategory? category;

  /// One-line gist from the enrichment stage. Null until enriched.
  final String? summary;

  /// The capture's tags: one normalized list, no provenance. Enrichment may
  /// propose it and the user may rewrite it — see [RecordingTags].
  final List<String> tags;

  /// Optional executable context. Null keeps legacy and unassigned captures
  /// fully valid; projects live in their own store and are never embedded here.
  final String? projectId;

  final String? error;

  /// User-level state. This is intentionally separate from AI processing.
  final bool isProcessedByUser;
  final DateTime? processedAt;

  /// Where this capture has been sent, oldest first. Empty on every legacy row
  /// and on anything never routed.
  ///
  /// It is what turns [isProcessedByUser] from an assertion into a record: the
  /// bit says the user is finished with the item, and this says why. Routing
  /// the same capture twice appends rather than replaces — both deliveries
  /// happened, and the second does not undo the first.
  final List<RouteRecord> routes;

  /// Agent output artifacts, connected notes, or research results produced for
  /// this capture. Empty on legacy rows and captures without agent results.
  final List<AgentArtifact> artifacts;

  Recording copyWith({
    RecordingStatus? status,
    String? contentHash,
    String? transcript,
    String? thumbPath,
    bool clearThumbPath = false,
    String? title,
    bool clearTitle = false,
    CaptureCategory? category,
    bool clearCategory = false,
    String? summary,
    bool clearSummary = false,
    List<String>? tags,
    String? projectId,
    bool clearProjectId = false,
    String? error,
    bool clearError = false,
    bool? isProcessedByUser,
    DateTime? processedAt,
    bool clearProcessedAt = false,
    List<RouteRecord>? routes,
    List<AgentArtifact>? artifacts,
  }) {
    return Recording(
      id: id,
      filePath: filePath,
      createdAt: createdAt,
      durationMs: durationMs,
      sizeBytes: sizeBytes,
      contentHash: contentHash ?? this.contentHash,
      type: type,
      sourceMimeType: sourceMimeType,
      status: status ?? this.status,
      transcript: transcript ?? this.transcript,
      thumbPath: clearThumbPath ? null : (thumbPath ?? this.thumbPath),
      title: clearTitle ? null : (title ?? this.title),
      category: clearCategory ? null : (category ?? this.category),
      summary: clearSummary ? null : (summary ?? this.summary),
      tags: RecordingTags.normalize(tags ?? this.tags),
      projectId: clearProjectId ? null : (projectId ?? this.projectId),
      error: clearError ? null : (error ?? this.error),
      isProcessedByUser: isProcessedByUser ?? this.isProcessedByUser,
      processedAt: clearProcessedAt ? null : (processedAt ?? this.processedAt),
      routes: routes ?? this.routes,
      artifacts: artifacts ?? this.artifacts,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'filePath': filePath,
    'createdAt': createdAt.toIso8601String(),
    'durationMs': durationMs,
    'sizeBytes': sizeBytes,
    'contentHash': contentHash,
    'status': status.name,
    'type': type.name,
    'sourceMimeType': sourceMimeType,
    'transcript': transcript,
    'thumbPath': thumbPath,
    'title': title,
    'category': category?.name,
    'summary': summary,
    'tags': tags,
    'projectId': projectId,
    'error': error,
    'isProcessedByUser': isProcessedByUser,
    'processedAt': processedAt?.toIso8601String(),
    'routes': routes.map((RouteRecord route) => route.toJson()).toList(),
    'artifacts': artifacts.map((AgentArtifact a) => a.toJson()).toList(),
  };

  factory Recording.fromJson(Map<String, dynamic> json) {
    return Recording(
      id: json['id'] as String,
      filePath: json['filePath'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      durationMs: json['durationMs'] as int,
      // Absent on every row written before the card showed a size.
      sizeBytes: json['sizeBytes'] as int? ?? 0,
      // Absent on every row written before content fingerprints existed.
      contentHash:
          json['contentHash'] is String &&
              _sha256.hasMatch(json['contentHash'] as String)
          ? json['contentHash'] as String
          : null,
      status: RecordingStatus.values.byName(json['status'] as String),
      // Legacy rows have no `type`; unknown names from a newer build degrade
      // the same way rather than throwing.
      type: CaptureType.fromName(json['type'] as String?),
      sourceMimeType: json['sourceMimeType'] as String?,
      transcript: json['transcript'] as String?,
      // Absent on every row written before posters existed, and type-checked
      // rather than cast for the same reason as `summary`: a hand-edited
      // recordings.json holding a non-string here would otherwise throw out of
      // the whole load. A null poster is simply "no thumbnail".
      thumbPath: json['thumbPath'] is String
          ? json['thumbPath'] as String
          : null,
      title: json['title'] as String?,
      // Absent on every row written before enrichment existed. A missing value
      // stays null — "never enriched" — while a *present* unknown name degrades
      // to `capture`, the same forward-compatibility rule as `type`.
      // Type-checked, not cast, for the same reason as `tags` below: a
      // hand-edited recordings.json holding a number here would otherwise throw
      // out of the whole load and take every other recording with it.
      category: json['category'] is String
          ? CaptureCategory.fromName(json['category'] as String)
          : null,
      summary: json['summary'] is String ? json['summary'] as String : null,
      // Reads the plain string list *and* the retired `{value, source}` form,
      // which is already on disk. Invalid entries degrade individually rather
      // than taking down the index.
      tags: RecordingTags.fromJson(json['tags']),
      projectId: json['projectId'] is String
          ? json['projectId'] as String
          : null,
      error: json['error'] as String?,
      isProcessedByUser: json['isProcessedByUser'] as bool? ?? false,
      processedAt: json['processedAt'] == null
          ? null
          : DateTime.parse(json['processedAt'] as String),
      // Absent on every row written before routing existed. Unreadable entries
      // are dropped one at a time rather than throwing out of the whole load —
      // the same rule `tags` and `category` follow.
      routes: RouteRecord.listFromJson(json['routes']),
      artifacts: AgentArtifact.listFromJson(json['artifacts']),
    );
  }
}

