/// The quantities a provider reported for one call.
///
/// All nullable, because "not reported" is a real answer: a local whisper.cpp
/// or Ollama server returns no usage at all, and that is not an error — those
/// endpoints also charge nothing.
class MeasuredUsage {
  const MeasuredUsage({this.inputTokens, this.outputTokens, this.audioSeconds});

  static const MeasuredUsage none = MeasuredUsage();

  final int? inputTokens;
  final int? outputTokens;
  final double? audioSeconds;

  bool get isEmpty =>
      inputTokens == null && outputTokens == null && audioSeconds == null;
}

/// Pull the reported quantities out of a decoded response body.
///
/// Handles the three shapes the supported providers emit — chat completions
/// (`prompt_tokens`/`completion_tokens`), OpenAI transcriptions (either
/// `input_tokens`/`output_tokens` or `{"type": "duration", "seconds": N}`), and
/// Groq's `x_groq.usage`. Never throws: a missing or malformed block yields
/// [MeasuredUsage.none], because a response that transcribed correctly must not
/// fail over its accounting.
MeasuredUsage parseUsage(Map<String, dynamic> envelope) {
  final Map<String, dynamic>? usage =
      _asMap(envelope['usage']) ?? _asMap(_asMap(envelope['x_groq'])?['usage']);
  if (usage == null) return MeasuredUsage.none;

  return MeasuredUsage(
    inputTokens: _asInt(usage['prompt_tokens'] ?? usage['input_tokens']),
    outputTokens: _asInt(usage['completion_tokens'] ?? usage['output_tokens']),
    audioSeconds: _asDouble(usage['seconds'] ?? usage['duration']),
  );
}

Map<String, dynamic>? _asMap(dynamic value) =>
    value is Map<String, dynamic> ? value : null;

int? _asInt(dynamic value) => value is num ? value.toInt() : null;

double? _asDouble(dynamic value) => value is num ? value.toDouble() : null;
