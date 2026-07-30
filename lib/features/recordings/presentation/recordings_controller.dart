import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

import '../../enrichment/domain/enrichment_result.dart';
import '../../enrichment/domain/enrichment_service.dart';
import '../../logs/domain/log_event.dart';
import '../../processing/data/ocr_service.dart';
import '../../processing/data/video_audio_extractor.dart';
import '../../processing/domain/processor.dart';
import '../../processing/domain/processor_registry.dart';
import '../../settings/domain/audio_config.dart';
import '../../transcription/data/transcription_service.dart';
import '../data/media_importer.dart';
import '../data/media_picker.dart';
import '../data/recordings_repository.dart';
import '../domain/capture_category.dart';
import '../domain/capture_type.dart';
import '../domain/clipboard_sink.dart';
import '../domain/recording.dart';

class RecordingsController extends ChangeNotifier {
  RecordingsController({
    required RecordingsRepository repository,
    required TranscriptionService transcriptionService,
    EnrichmentService enrichmentService = const DisabledEnrichmentService(),
    OcrService ocrService = const DisabledOcrService(),
    VideoAudioExtractor videoAudioExtractor =
        const UnavailableVideoAudioExtractor(),
    AudioConfig audioConfig = AudioConfig.defaults,
    LogSink logSink = const NoopLogSink(),
    ClipboardSink clipboardSink = const NoopClipboardSink(),
    ProcessorRegistry? processorRegistry,
    MediaPicker? mediaPicker,
    AudioRecorder? recorder,
    AudioPlayer? player,
  })  : _repository = repository,
        _transcriptionService = transcriptionService,
        _enrichmentService = enrichmentService,
        _ocrService = ocrService,
        _videoAudioExtractor = videoAudioExtractor,
        _audioConfig = audioConfig,
        _logSink = logSink,
        _clipboardSink = clipboardSink,
        _mediaPicker = mediaPicker ?? const FilePickerMediaPicker(),
        _importer = MediaImporter(repository),
        _recorder = recorder ?? AudioRecorder(),
        _player = player ?? AudioPlayer() {
    // The default registry resolves the services lazily, so the Models/Config
    // tabs can keep swapping them without rebuilding the registry.
    _registry = processorRegistry ??
        ProcessorRegistry.standard(
          transcriptionService: () => _transcriptionService,
          ocrService: () => _ocrService,
          videoAudioExtractor: () => _videoAudioExtractor,
        );
    // Reset the "now playing" marker when a clip finishes on its own.
    _playerCompleteSub = _player.onPlayerComplete.listen((_) {
      _playingId = null;
      notifyListeners();
    });
  }

  final RecordingsRepository _repository;
  final LogSink _logSink;
  final ClipboardSink _clipboardSink;
  final MediaPicker _mediaPicker;
  final MediaImporter _importer;
  late final ProcessorRegistry _registry;

  // All swappable at runtime from the Models/Config tabs. A swap only affects
  // work started afterwards; it never touches an in-flight pipeline.
  TranscriptionService _transcriptionService;
  EnrichmentService _enrichmentService;
  OcrService _ocrService;
  VideoAudioExtractor _videoAudioExtractor;
  AudioConfig _audioConfig;

  final AudioRecorder _recorder;
  final AudioPlayer _player;
  StreamSubscription<void>? _playerCompleteSub;

  final Stopwatch _stopwatch = Stopwatch();
  final ValueNotifier<Duration> _elapsedTicker =
      ValueNotifier<Duration>(Duration.zero);
  final ValueNotifier<double> _levelTicker = ValueNotifier<double>(0);
  StreamSubscription<Amplitude>? _amplitudeSub;
  Timer? _timer;
  List<Recording> _recordings = <Recording>[];
  bool _isRecording = false;
  bool _isBusy = false;
  String? _activeFilePath;
  String? _activeId;
  String? _playingId;
  String? _error;

  // Background processing queue. Capture enqueues an already-persisted item and
  // returns immediately; `_drainProcessingQueue` runs jobs one at a time off the
  // `_isBusy` capture lock, so a long job no longer blocks the next capture.
  final List<String> _processingQueue = <String>[];
  bool _isDraining = false;
  bool _disposed = false;
  String? _processingId; // the id currently running in the drain loop, if any
  Future<void>? _saveInFlight; // serializes saveAll (shared temp file)

  List<Recording> get recordings => List<Recording>.unmodifiable(_recordings);
  bool get isRecording => _isRecording;
  bool get isBusy => _isBusy;

  /// Whether the background processing loop is currently running a job.
  bool get isProcessing => _isDraining;

  /// Items currently in the processing pipeline — queued (`pendingTranscription`)
  /// plus the one running (`transcribing`). Derived from status so it always
  /// matches what the queue renders.
  int get pendingProcessingCount => _recordings
      .where((Recording item) =>
          item.status == RecordingStatus.pendingTranscription ||
          item.status == RecordingStatus.transcribing)
      .length;
  Duration get elapsed => _stopwatch.elapsed;

  /// Ticks every 250 ms while recording. Listen to this instead of the
  /// controller when all you render is the running time — it repaints one label
  /// rather than the whole page.
  ValueListenable<Duration> get elapsedTicker => _elapsedTicker;

  /// Input level, `0`–`1`, while recording. Same reasoning as [elapsedTicker]:
  /// the waveform is the only thing that repaints at this rate, so it listens
  /// on its own rather than dragging the whole page along.
  ///
  /// Stays at `0` on a platform that reports no amplitude — the meter then just
  /// sits flat, which is honest, rather than animating invented values.
  ValueListenable<double> get levelTicker => _levelTicker;
  String? get playingId => _playingId;
  String? get error => _error;
  AudioConfig get audioConfig => _audioConfig;

  /// Applied to the next transcription attempt. A job already running keeps the
  /// service it started with.
  set transcriptionService(TranscriptionService value) {
    if (identical(_transcriptionService, value)) return;
    _transcriptionService = value;
  }

  /// Applied to the next enrichment attempt. A job already running keeps the
  /// service it started with.
  set enrichmentService(EnrichmentService value) {
    if (identical(_enrichmentService, value)) return;
    _enrichmentService = value;
  }

  /// Applied to the next image OCR attempt. A job already running keeps the
  /// service it started with.
  set ocrService(OcrService value) {
    if (identical(_ocrService, value)) return;
    _ocrService = value;
  }

  /// Applied to the next video processing attempt. A job already running keeps
  /// the extractor it started with.
  set videoAudioExtractor(VideoAudioExtractor value) {
    if (identical(_videoAudioExtractor, value)) return;
    _videoAudioExtractor = value;
  }

  /// Applied to the next capture. Never changes a recording already on disk.
  set audioConfig(AudioConfig value) {
    if (_audioConfig == value) return;
    _audioConfig = value;
  }

  Future<void> initialize() async {
    _recordings = await _repository.loadAll();
    _logSink.log('Loaded ${_recordings.length} captures from disk.');
    notifyListeners();

    // Resume jobs left non-terminal by a previous session (the app was killed
    // mid-processing). Their source is already on disk, so re-enqueuing is safe
    // and idempotent — the same persist-then-process invariant.
    final List<String> stuck = _recordings
        .where((Recording item) =>
            item.status == RecordingStatus.pendingTranscription ||
            item.status == RecordingStatus.transcribing)
        .map((Recording item) => item.id)
        .toList();
    for (final String id in stuck) {
      await _enqueueProcessing(id);
    }
  }

  Future<void> startRecording() async {
    if (_isRecording || _isBusy) return;
    _error = null;

    final bool allowed = await _recorder.hasPermission();
    if (!allowed) {
      _error = 'Microphone permission denied.';
      _logSink.log('Microphone access refused.', level: LogLevel.error);
      notifyListeners();
      return;
    }

    final String id = const Uuid().v4();
    final File audioFile = await _repository.createAudioFile(id);
    _activeFilePath = audioFile.path;
    _activeId = id;

    await _recorder.start(
      RecordConfig(
        encoder: AudioEncoder.aacLc,
        sampleRate: _audioConfig.sampleRate,
        numChannels: _audioConfig.numChannels,
        bitRate: _audioConfig.bitRate,
      ),
      path: audioFile.path,
    );
    _logSink.log(
      'Recording started · ${_audioConfig.sampleRate} Hz · '
      '${_audioConfig.numChannels} channel(s) · ${_audioConfig.bitRate ~/ 1000} kbps',
      recordingId: id,
    );

    _stopwatch
      ..reset()
      ..start();
    // Reset before the first tick lands, or the label shows the previous
    // recording's duration for up to 250 ms.
    _elapsedTicker.value = Duration.zero;
    // Ticks into `elapsedTicker` rather than notifyListeners(): the elapsed time
    // is read in exactly one place (the capture FAB's mm:ss label), but a
    // controller-wide notification rebuilds the whole page — and the shell's
    // IndexedStack builds all four tabs, so Logs would re-scan its 500-event
    // buffer four times a second while nobody is looking at it.
    _timer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => _elapsedTicker.value = _stopwatch.elapsed,
    );
    _listenToLevel();
    _isRecording = true;
    notifyListeners();
  }

  /// Feed the capture screen's meter from the recorder's own amplitude stream.
  ///
  /// Wrapped because amplitude reporting is optional: a platform (or a test
  /// double) that does not implement it throws here, and a missing meter must
  /// never be the reason a recording fails to start.
  void _listenToLevel() {
    _levelTicker.value = 0;
    try {
      _amplitudeSub = _recorder
          .onAmplitudeChanged(const Duration(milliseconds: 120))
          .listen(
            (Amplitude amplitude) =>
                _levelTicker.value = _normalizeLevel(amplitude.current),
            onError: (Object _) => _levelTicker.value = 0,
          );
    } catch (_) {
      _amplitudeSub = null;
    }
  }

  /// dBFS → `0`–`1`. Everything below −45 dB is silence for meter purposes;
  /// the floor the platforms report varies (−160, −120, −60), so clamping to a
  /// fixed window is what keeps the bars comparable across them.
  static double _normalizeLevel(double dbfs) {
    if (dbfs.isNaN || dbfs.isInfinite) return 0;
    return ((dbfs + 45) / 45).clamp(0, 1).toDouble();
  }

  Future<void> stopRecording() async {
    if (!_isRecording || _isBusy) return;
    _isBusy = true;
    notifyListeners();

    try {
      final String? stoppedPath = await _recorder.stop();
      _timer?.cancel();
      unawaited(_amplitudeSub?.cancel());
      _amplitudeSub = null;
      _levelTicker.value = 0;
      _stopwatch.stop();
      _isRecording = false;

      final String? path = stoppedPath ?? _activeFilePath;
      if (path == null) {
        throw FileSystemException('Recorder did not return a file path.');
      }

      final File file = File(path);
      // One `length()` call serves both jobs: it is the emptiness check that
      // gates persistence, and it is the size the card reports afterwards.
      final int sizeBytes = await file.exists() ? await file.length() : 0;
      if (sizeBytes == 0) {
        throw FileSystemException('Recording file was not persisted correctly.', path);
      }

      // Use the id generated at record start rather than parsing it back out of
      // the filename: extensions vary per capture type, and the round-trip
      // through the path was the only thing coupling id to `.m4a`.
      final String id = _activeId ?? p.basenameWithoutExtension(path);
      final Recording saved = Recording(
        id: id,
        filePath: path,
        createdAt: DateTime.now(),
        durationMs: _stopwatch.elapsedMilliseconds,
        sizeBytes: sizeBytes,
        status: RecordingStatus.saved,
        type: CaptureType.audioRecording,
      );

      // Critical invariant: persist metadata only after the audio file exists.
      _recordings = <Recording>[saved, ..._recordings];
      await _persistAll();
      _logSink.log(
        'File verified and saved · $sizeBytes B',
        recordingId: saved.id,
      );

      // Processing is a separate step and starts only after durable save.
      // Enqueue for background processing and return; the drain loop runs the
      // job off the capture lock so it never blocks the next capture.
      await _enqueueProcessing(saved.id);
    } catch (exception) {
      _error = exception.toString();
      _logSink.log('Failed to save recording: $exception', level: LogLevel.error);
    } finally {
      _isBusy = false;
      _activeFilePath = null;
      _activeId = null;
      notifyListeners();
    }
  }

  /// Save a typed text note. Follows the exact ordering of [stopRecording]:
  /// write the `.txt` source, verify it exists with length > 0, build the item
  /// with status `saved`, persist the index, and only then process it. The
  /// text processor is a passthrough, so the item lands `completed` — but it
  /// travels the same persist-then-process path as every other capture, and a
  /// failure never deletes the source.
  Future<void> addTextNote(String body) async {
    if (_isRecording || _isBusy) return;
    final String trimmed = body.trim();
    if (trimmed.isEmpty) return;

    _isBusy = true;
    _error = null;
    notifyListeners();

    try {
      final String id = const Uuid().v4();
      final File file = await _repository.createSourceFile(id, 'txt');
      await file.writeAsString(trimmed, flush: true);
      final int sizeBytes = await file.exists() ? await file.length() : 0;
      if (sizeBytes == 0) {
        throw FileSystemException('Note file was not persisted correctly.', file.path);
      }

      final Recording saved = Recording(
        id: id,
        filePath: file.path,
        createdAt: DateTime.now(),
        durationMs: 0,
        sizeBytes: sizeBytes,
        status: RecordingStatus.saved,
        type: CaptureType.text,
        sourceMimeType: 'text/plain',
      );

      // Critical invariant: index the note only after the .txt exists on disk.
      _recordings = <Recording>[saved, ..._recordings];
      await _persistAll();
      _logSink.log('Note saved · $sizeBytes B', recordingId: saved.id);

      // Enqueue for background processing and return; the drain loop runs the
      // job off the capture lock so it never blocks the next capture.
      await _enqueueProcessing(saved.id);
    } catch (exception) {
      _error = exception.toString();
      _logSink.log('Failed to save note: $exception', level: LogLevel.error);
    } finally {
      _isBusy = false;
      notifyListeners();
    }
  }

  /// Import an existing file (audio, image or video) as a new item. Mirrors the
  /// ordering of [stopRecording]: pick, copy the source into the app directory
  /// and verify it (via [MediaImporter]), index with status `saved`, and only
  /// then process. A cancelled pick is a no-op; a copy or processing failure
  /// never deletes the source.
  Future<void> addUpload(CaptureType type) async {
    if (_isRecording || _isBusy) return;
    _isBusy = true;
    _error = null;
    notifyListeners();

    try {
      final PickedMedia? picked = await _mediaPicker.pick(type);
      if (picked == null) return; // user cancelled

      final String id = const Uuid().v4();
      final Recording saved = await _importer.importFile(
        id: id,
        type: type,
        source: picked.file,
        mimeType: picked.mimeType,
        createdAt: DateTime.now(),
      );

      // Critical invariant: index only after the source is copied and verified.
      _recordings = <Recording>[saved, ..._recordings];
      await _persistAll();
      _logSink.log(
        'File imported · ${type.name} · ${await File(saved.filePath).length()} B',
        recordingId: saved.id,
      );

      // Enqueue for background processing and return; the drain loop runs the
      // job off the capture lock so it never blocks the next capture.
      await _enqueueProcessing(saved.id);
    } catch (exception) {
      _error = exception.toString();
      _logSink.log('Failed to import file: $exception', level: LogLevel.error);
    } finally {
      _isBusy = false;
      notifyListeners();
    }
  }

  /// Play the recording's audio, or stop it if it is already playing.
  /// Independent of the transcription pipeline and the `_isBusy` lock.
  Future<void> togglePlayback(String id) async {
    _error = null;
    try {
      if (_playingId == id) {
        await _player.stop();
        _playingId = null;
        notifyListeners();
        return;
      }

      final Recording recording =
          _recordings.firstWhere((Recording item) => item.id == id);
      final File file = File(recording.filePath);
      if (!await file.exists()) {
        throw FileSystemException('Source file is missing.', recording.filePath);
      }

      await _player.stop();
      _playingId = id;
      notifyListeners();
      await _player.play(DeviceFileSource(recording.filePath));
    } catch (exception) {
      _playingId = null;
      _error = exception.toString();
      _logSink.log(
        'Playback failed: $exception',
        level: LogLevel.error,
        recordingId: id,
      );
      notifyListeners();
    }
  }

  /// Overwrite an item's processor-output text (transcript / OCR / note body)
  /// with a user edit. Distinct from [retryTranscription], which re-runs the
  /// processor. A blank edit is ignored so an item is never left textless.
  Future<void> editTranscript(String id, String text) async {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) return;
    await _update(id, (Recording item) => item.copyWith(transcript: trimmed));
    _logSink.log('Text updated.', recordingId: id);
  }

  /// Set or clear an item's display title. An empty value clears it (the card
  /// falls back to the filename).
  Future<void> setTitle(String id, String? title) async {
    final String trimmed = (title ?? '').trim();
    await _update(
      id,
      (Recording item) => item.copyWith(
        title: trimmed.isEmpty ? null : trimmed,
        clearTitle: trimmed.isEmpty,
      ),
    );
    _logSink.log(
      trimmed.isEmpty ? 'Title cleared.' : 'Title set.',
      recordingId: id,
    );
  }

  /// Overwrite the model's verdict. Null clears it back to "unclassified" — a
  /// wrong category is worse than none, because an export will read this field.
  Future<void> setCategory(String id, CaptureCategory? category) async {
    await _update(
      id,
      (Recording item) => item.copyWith(
        category: category,
        clearCategory: category == null,
      ),
    );
    _logSink.log(
      category == null
          ? 'Category cleared.'
          : 'Category set \u00b7 ${category.name}',
      recordingId: id,
    );
  }

  Future<void> toggleProcessed(String id) async {
    final Recording recording =
        _recordings.firstWhere((Recording item) => item.id == id);
    final bool nextValue = !recording.isProcessedByUser;

    await _update(
      id,
      (Recording item) => item.copyWith(
        isProcessedByUser: nextValue,
        processedAt: nextValue ? DateTime.now() : null,
        clearProcessedAt: !nextValue,
      ),
    );
  }

  /// Re-queue a failed (or any) item for processing. Like capture, this only
  /// enqueues — it does not hold the `_isBusy` capture lock, so a retry never
  /// blocks starting a new recording.
  Future<void> retryTranscription(String id) async {
    _logSink.log('Retrying processing.', level: LogLevel.warn, recordingId: id);
    await _enqueueProcessing(id);
  }

  /// Mark an already-persisted item `pendingTranscription`, add it to the
  /// processing queue, and kick the drain loop if it is idle. Returns once the
  /// queued state is persisted; the actual processing runs in the background.
  /// De-dupes so a double capture/retry cannot enqueue the same item twice.
  Future<void> _enqueueProcessing(String id) async {
    // Idempotent: don't re-enqueue an item that is already queued or currently
    // running — that would process it twice (the UI only ever retries `failed`
    // items, so this is a defensive guard).
    if (id == _processingId || _processingQueue.contains(id)) return;
    _processingQueue.add(id);
    await _update(
      id,
      (Recording item) => item.copyWith(
        status: RecordingStatus.pendingTranscription,
        clearError: true,
      ),
    );
    _logSink.log('Queued for processing.', recordingId: id);
    unawaited(_drainProcessingQueue());
  }

  /// Test helper: await until the background queue has fully drained. Processing
  /// is now asynchronous — capture returns before jobs finish — so tests that
  /// assert a `completed` status must await this first.
  @visibleForTesting
  Future<void> waitForProcessing() async {
    int guard = 0;
    while ((_isDraining || pendingProcessingCount > 0) && guard++ < 10000) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Drain the processing queue one job at a time, in the background. Runs
  /// independently of the `_isBusy` capture lock so captures proceed while jobs
  /// run; `_isDraining` keeps it single-flight so at most one job runs at once.
  Future<void> _drainProcessingQueue() async {
    if (_isDraining) return;
    _isDraining = true;
    notifyListeners();
    try {
      while (_processingQueue.isNotEmpty && !_disposed) {
        final String id = _processingQueue.removeAt(0);
        // The item could have been dropped between enqueue and now; skip it.
        if (!_recordings.any((Recording item) => item.id == id)) continue;
        await _processOne(id);
      }
    } finally {
      _isDraining = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Run the processor for one item: `transcribing` → `completed`/`failed`, then
  /// the clipboard hand-off. Same state machine for every [CaptureType]; only
  /// the processor differs. Never touches the source file.
  Future<void> _processOne(String id) async {
    _processingId = id; // marks this id in-flight so it can't be re-enqueued
    try {
      await _update(
        id,
        (Recording item) => item.copyWith(status: RecordingStatus.transcribing),
      );
      _logSink.log('Processing started.', recordingId: id);

      final Recording recording =
          _recordings.firstWhere((Recording item) => item.id == id);
      // Pin the processor for this job: a runtime swap (Models tab) during the
      // await gaps above must not redirect a job that already started.
      final Processor processor = _registry.forType(recording.type);
      try {
        final String transcript = await processor.process(recording);
        await _update(
          id,
          (Recording item) => item.copyWith(
            status: RecordingStatus.completed,
            transcript: transcript,
            clearError: true,
          ),
        );
        _logSink.log(
          'Processing finished · ${transcript.length} characters',
          recordingId: id,
        );
        // Deliberately last: the item is already `completed` and persisted, so a
        // refusing clipboard cannot undo a successful capture.
        await _copyToClipboard(recording.type, transcript, id);
        // Deliberately after the `completed` write as well: the item is already
        // durable, so a model outage, a malformed response or a kill in this
        // window costs a title, never a capture.
        await _enrich(id, transcript);
      } catch (exception) {
        await _update(
          id,
          (Recording item) => item.copyWith(
            status: RecordingStatus.failed,
            error: exception.toString(),
          ),
        );
        _logSink.log(
          'Processing failed: $exception',
          level: LogLevel.error,
          recordingId: id,
        );
      }
    } finally {
      _processingId = null;
    }
  }

  /// Hand freshly derived text to the clipboard so a clipboard manager records
  /// it as a history entry. Text notes are skipped: their processor output is
  /// the body the user just typed, so nothing was derived worth handing back.
  ///
  /// Swallows every error, on the same rule as logging — this runs after the
  /// item is already `completed` on disk and must never fail the pipeline.
  Future<void> _copyToClipboard(CaptureType type, String text, String id) async {
    if (type == CaptureType.text || text.trim().isEmpty) return;
    try {
      await _clipboardSink.copy(text);
      _logSink.log('Result copied to clipboard.', recordingId: id);
    } catch (exception) {
      _logSink.log(
        'Clipboard copy failed: $exception',
        level: LogLevel.warn,
        recordingId: id,
      );
    }
  }

  /// Ask the enrichment model to name and classify freshly derived text.
  ///
  /// Best-effort by construction: it runs after the item is `completed` on
  /// disk, it never touches `status`, and it swallows every error into the log
  /// — the same contract as [_copyToClipboard]. An unconfigured install throws
  /// `EnrichmentNotConfiguredException` here on every item, which is why that
  /// case is logged at `warn` rather than `error`.
  Future<void> _enrich(String id, String text) async {
    if (text.trim().isEmpty) return;
    try {
      final EnrichmentResult result = await _enrichmentService.enrich(text);
      if (_disposed) return;
      await _update(
        id,
        (Recording item) => item.copyWith(
          // Title and category are the two fields the user can correct by hand,
          // so enrichment only ever *fills* them: an already-set value survives
          // a retry. Summary and tags have no editor, so they are pure derived
          // output and a re-run refreshes them.
          title: (item.title ?? '').trim().isEmpty ? result.title : null,
          category: item.category ?? result.category,
          summary: result.summary,
          tags: result.tags,
        ),
      );
      _logSink.log('Enriched \u00b7 ${result.category.name}', recordingId: id);
    } on EnrichmentNotConfiguredException {
      // Expected on every item until a profile is configured; not an error.
      _logSink.log(
        'Enrichment skipped \u2014 no profile configured.',
        level: LogLevel.warn,
        recordingId: id,
      );
    } catch (exception) {
      _logSink.log(
        'Enrichment failed: $exception',
        level: LogLevel.warn,
        recordingId: id,
      );
    }
  }

  Future<void> _update(String id, Recording Function(Recording) transform) async {
    _recordings = _recordings
        .map((Recording item) => item.id == id ? transform(item) : item)
        .toList();
    // Persist even after dispose: the drain can be mid-job when the shell tears
    // the page down, and the status it just computed still belongs on disk.
    await _persistAll();
    // Notifying does not. `_processOne` awaits a processor, so dispose can land
    // inside that gap; a disposed ChangeNotifier throws from notifyListeners,
    // and the drain runs unawaited, so the error would surface as an unhandled
    // async exception with the queue left mid-flight.
    if (!_disposed) notifyListeners();
  }

  /// Serialized write of the whole index. `RecordingsRepository.saveAll` writes
  /// a single shared `.tmp` file, so two concurrent calls would corrupt it — and
  /// with processing now off the `_isBusy` lock, a capture/retry save can race a
  /// drain save. Wait for any in-flight write, then persist the latest state.
  Future<void> _persistAll() async {
    while (_saveInFlight != null) {
      await _saveInFlight;
    }
    final Future<void> mine = _repository.saveAll(_recordings);
    _saveInFlight = mine;
    try {
      await mine;
    } finally {
      if (identical(_saveInFlight, mine)) _saveInFlight = null;
    }
  }

  @override
  void dispose() {
    _disposed = true; // lets an in-flight drain loop exit at the next boundary
    _timer?.cancel();
    unawaited(_amplitudeSub?.cancel());
    _elapsedTicker.dispose();
    _levelTicker.dispose();
    _playerCompleteSub?.cancel();
    _player.dispose();
    _recorder.dispose();
    super.dispose();
  }
}
