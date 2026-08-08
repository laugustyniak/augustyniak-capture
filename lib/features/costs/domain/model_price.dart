/// What one model charges.
///
/// Every field is nullable because the two billing shapes are disjoint: a chat
/// model has token rates and no per-minute rate, a transcription model has the
/// opposite. A field that is null means "this model is not billed that way",
/// never "free".
class ModelPrice {
  const ModelPrice({
    this.inputPerMTok,
    this.outputPerMTok,
    this.perAudioMinute,
  });

  /// USD per 1 000 000 input tokens.
  final double? inputPerMTok;

  /// USD per 1 000 000 output tokens.
  final double? outputPerMTok;

  /// USD per minute of audio. Providers quoting an hourly rate are divided by
  /// 60 in the defaults table so this field has one unit everywhere.
  final double? perAudioMinute;

  /// True when the entry carries no rate at all — what an editor produces when
  /// every field is cleared, and what must not be stored as an override.
  bool get isEmpty =>
      inputPerMTok == null && outputPerMTok == null && perAudioMinute == null;

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (inputPerMTok != null) 'inputPerMTok': inputPerMTok,
    if (outputPerMTok != null) 'outputPerMTok': outputPerMTok,
    if (perAudioMinute != null) 'perAudioMinute': perAudioMinute,
  };

  factory ModelPrice.fromJson(Map<String, dynamic> json) => ModelPrice(
    inputPerMTok: (json['inputPerMTok'] as num?)?.toDouble(),
    outputPerMTok: (json['outputPerMTok'] as num?)?.toDouble(),
    perAudioMinute: (json['perAudioMinute'] as num?)?.toDouble(),
  );
}
