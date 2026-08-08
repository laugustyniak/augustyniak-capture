/// Which pipeline stage spent the money.
///
/// Unlike [UnpricedReason], an unrecognised stage **drops the row**: there is no
/// sensible stage to assume, and filing a cost under the wrong stage is worse
/// than losing one row of history. Same rule `RouteKind.fromName` follows.
enum UsageStage {
  transcription,
  ocr,
  enrichment;

  static UsageStage? fromName(String? name) =>
      name == null ? null : UsageStage.values.asNameMap()[name];

  /// Section label in the editor's COST panel.
  String get label => switch (this) {
    UsageStage.transcription => 'TRANSCRIPTION',
    UsageStage.ocr => 'OCR',
    UsageStage.enrichment => 'ENRICHMENT',
  };
}

/// Why an event carries no cost. Set **exactly when** `costUsd` is null.
///
/// The two are not interchangeable and must not be shown together: [noRate] is
/// fixed by typing a rate in the Config tab and is backfillable afterwards,
/// while [noQuantity] means the rate exists and the billable amount is unknown —
/// typing a rate there fixes nothing.
enum UnpricedReason {
  /// The price book had no entry for this model.
  noRate,

  /// The provider reported no billable quantity and none could be supplied.
  noQuantity;

  /// Unknown names degrade to null rather than dropping the row: the row's
  /// tokens and model are still worth keeping, and the reason is a hint.
  static UnpricedReason? fromName(String? name) =>
      name == null ? null : UnpricedReason.values.asNameMap()[name];
}

/// One API call, what it consumed, and what it cost.
///
/// One capture produces several of these: a long recording is split into N
/// transcription requests, a retry runs the whole pass again, and enrichment is
/// its own request after the transcript lands. The cost of a capture is a sum
/// over this list, never a single field.
class UsageEvent {
  const UsageEvent({
    required this.id,
    required this.captureId,
    required this.stage,
    required this.provider,
    required this.model,
    required this.at,
    this.inputTokens,
    this.outputTokens,
    this.audioSeconds,
    this.costUsd,
    this.unpricedReason,
  });

  final String id;
  final String captureId;
  final UsageStage stage;

  /// Endpoint host (`api.openai.com`), so the Config tab can group by provider
  /// and name the endpoint behind a blank model.
  final String provider;

  /// Model name, or `''` when the profile sets none (a local server that
  /// ignores the field). Blank is a real state, not a missing one.
  final String model;
  final DateTime at;

  /// Null when the provider reported none. Detail rather than price basis for
  /// [UsageStage.transcription], which every supported provider bills by time.
  final int? inputTokens;
  final int? outputTokens;

  /// The billable quantity for [UsageStage.transcription]. Null when neither
  /// the response nor the capture could supply it.
  final double? audioSeconds;

  /// Computed and stored at record time, because it is a fact about what was
  /// paid. A later price change must not rewrite it; only a null is ever
  /// backfilled.
  final double? costUsd;

  /// Set exactly when [costUsd] is null.
  final UnpricedReason? unpricedReason;

  UsageEvent copyWith({
    double? costUsd,
    UnpricedReason? unpricedReason,
    bool clearUnpricedReason = false,
  }) {
    return UsageEvent(
      id: id,
      captureId: captureId,
      stage: stage,
      provider: provider,
      model: model,
      at: at,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      audioSeconds: audioSeconds,
      costUsd: costUsd ?? this.costUsd,
      unpricedReason: clearUnpricedReason
          ? null
          : (unpricedReason ?? this.unpricedReason),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'captureId': captureId,
    'stage': stage.name,
    'provider': provider,
    'model': model,
    'at': at.toIso8601String(),
    'inputTokens': inputTokens,
    'outputTokens': outputTokens,
    'audioSeconds': audioSeconds,
    'costUsd': costUsd,
    'unpricedReason': unpricedReason?.name,
  };

  /// Throws on a row with no usable stage; [listFromJson] is what turns that
  /// into a dropped row rather than a failed load.
  factory UsageEvent.fromJson(Map<String, dynamic> json) {
    final UsageStage? stage = UsageStage.fromName(json['stage'] as String?);
    if (stage == null) {
      throw FormatException('Unknown usage stage: ${json['stage']}');
    }
    return UsageEvent(
      id: json['id'] as String,
      captureId: json['captureId'] as String,
      stage: stage,
      provider: json['provider'] as String? ?? '',
      model: json['model'] as String? ?? '',
      at: DateTime.parse(json['at'] as String),
      inputTokens: (json['inputTokens'] as num?)?.toInt(),
      outputTokens: (json['outputTokens'] as num?)?.toInt(),
      audioSeconds: (json['audioSeconds'] as num?)?.toDouble(),
      costUsd: (json['costUsd'] as num?)?.toDouble(),
      unpricedReason: UnpricedReason.fromName(
        json['unpricedReason'] as String?,
      ),
    );
  }

  /// Unreadable rows are dropped one at a time rather than taking the whole
  /// load down — the same rule `RouteRecord.listFromJson` follows.
  static List<UsageEvent> listFromJson(dynamic value) {
    if (value is! List<dynamic>) return const <UsageEvent>[];
    final List<UsageEvent> events = <UsageEvent>[];
    for (final dynamic item in value) {
      if (item is! Map<String, dynamic>) continue;
      try {
        events.add(UsageEvent.fromJson(item));
      } catch (_) {
        continue;
      }
    }
    return events;
  }
}
