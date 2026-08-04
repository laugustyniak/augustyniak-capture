import 'dart:io';

import '../../logs/domain/log_event.dart';
import 'audio_splitter.dart';
import 'transcription_service.dart';

/// Sends long audio as several requests instead of one, and joins the answers.
///
/// It exists for a failure that does not look like one: the `gpt-4o` transcribe
/// family answers **HTTP 200 with a truncated `text`** once a recording passes
/// its 2000-token output ceiling, so a twenty-minute capture came back as nine
/// minutes of transcript, was written `completed`, and had its title enriched
/// from the part that survived. Nothing in the pipeline could tell.
///
/// **A decorator on [TranscriptionService], deliberately, rather than logic in
/// `TranscriptionProcessor`.** All three paths that produce audio — a mic
/// capture, an uploaded file, and the track `VideoTranscriptionProcessor`
/// extracts from a video — meet on this interface and nowhere else. Putting the
/// split here covers all three with one object; putting it in the processor
/// would have covered one and left the other two to duplicate it.
class ChunkedTranscriptionService implements TranscriptionService {
  const ChunkedTranscriptionService(
    this._inner,
    this._splitter, {
    this.maxSegment = defaultSegment,
    LogSink logSink = const NoopLogSink(),
  }) : _logSink = logSink;

  /// Five minutes, against a ceiling that reproduces near eight.
  ///
  /// The margin is the point: the observed ceiling comes from English, Polish
  /// tokenizes denser, and a fast speaker eats it faster still. Going down to
  /// two minutes would buy margin that is no longer needed and pay for it with
  /// nine cut boundaries on a twenty-minute capture instead of three — every
  /// boundary being a place a word can be halved. Going up to eight removes the
  /// margin entirely and puts the silent failure back on the table.
  static const Duration defaultSegment = Duration(minutes: 5);

  final TranscriptionService _inner;
  final AudioSplitter _splitter;
  final Duration maxSegment;
  final LogSink _logSink;

  @override
  Future<String> transcribe(File audioFile) async {
    final AudioSegments segments = await _splitter.split(audioFile, maxSegment);

    // The common case — a note shorter than the segment, or a platform with no
    // splitter. Hand the caller's own file straight to the inner service so the
    // short-recording path stays byte-identical to what it was.
    if (!segments.isSplit) return _inner.transcribe(audioFile);

    _logSink.log(
      'Audio exceeds ${maxSegment.inMinutes} min — transcribing in '
      '${segments.files.length} parts.',
    );

    try {
      final List<String> parts = <String>[];
      for (final File segment in segments.files) {
        // Sequential on purpose. The join order is then the loop order, so no
        // index bookkeeping can get it wrong, and concurrent uploads would only
        // buy latency at the price of the provider's rate limit — four requests
        // is not where the time goes.
        parts.add((await _inner.transcribe(segment)).trim());
      }
      return parts.where((String part) => part.isNotEmpty).join(' ');
    } finally {
      await segments.dispose();
    }
  }
}
