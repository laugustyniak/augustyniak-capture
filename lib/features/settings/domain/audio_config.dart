/// Capture parameters for the recorder.
///
/// The encoder is intentionally not configurable: `RecordingsRepository`
/// hardcodes the `.m4a` container, so switching to Opus or WAV would produce
/// files whose extension lies about their contents. Only the parameters that
/// are safe inside an AAC-LC/M4A file are exposed.
class AudioConfig {
  const AudioConfig({
    this.sampleRate = 16000,
    this.numChannels = 1,
    this.bitRate = 64000,
  });

  static const AudioConfig defaults = AudioConfig();

  /// Values offered in the Config tab. Whisper-family models resample to
  /// 16 kHz anyway, so higher rates only cost storage.
  static const List<int> sampleRateOptions = <int>[8000, 16000, 22050, 44100];
  static const List<int> bitRateOptions = <int>[32000, 64000, 96000, 128000];

  final int sampleRate;
  final int numChannels;
  final int bitRate;

  bool get isMono => numChannels == 1;

  AudioConfig copyWith({int? sampleRate, int? numChannels, int? bitRate}) {
    return AudioConfig(
      sampleRate: sampleRate ?? this.sampleRate,
      numChannels: numChannels ?? this.numChannels,
      bitRate: bitRate ?? this.bitRate,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'sampleRate': sampleRate,
        'numChannels': numChannels,
        'bitRate': bitRate,
      };

  factory AudioConfig.fromJson(Map<String, dynamic> json) {
    return AudioConfig(
      sampleRate: json['sampleRate'] as int? ?? defaults.sampleRate,
      numChannels: json['numChannels'] as int? ?? defaults.numChannels,
      bitRate: json['bitRate'] as int? ?? defaults.bitRate,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AudioConfig &&
      other.sampleRate == sampleRate &&
      other.numChannels == numChannels &&
      other.bitRate == bitRate;

  @override
  int get hashCode => Object.hash(sampleRate, numChannels, bitRate);
}
