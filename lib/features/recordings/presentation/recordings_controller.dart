import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

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
import '../domain/capture_type.dart';
import '../domain/clipboard_sink.dart';
import '../domain/recording.dart';

class RecordingsController extends ChangeNotifier {
  RecordingsController({
    required RecordingsRepository repository,
    required TranscriptionService transcriptionService,
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
  OcrService _ocrService;
  VideoAudioExtractor _videoAudioExtractor;
  AudioConfig _audioConfig;

  final AudioRecorder _recorder;
  final AudioPlayer _player;
  StreamSubscription<void>? _playerCompleteSub;

  final Stopwatch _stopwatch = Stopwatch();
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
  String? get playingId => _playingId;
  String? get error => _error;
  AudioConfig get audioConfig => _audioConfig;

  /// Applied to the next transcription attempt. A job already running keeps the
  /// service it started with.
  set transcriptionService(TranscriptionService value) {
    if (identical(_transcriptionService, value)) return;
    _transcriptionService = value;
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
    _logSink.log('Wczytano ${_recordings.length} nagrań z dysku.');
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
      _error = 'Brak uprawnienia do mikrofonu.';
      _logSink.log('Odmowa dostępu do mikrofonu.', level: LogLevel.error);
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
      'Start nagrywania · ${_audioConfig.sampleRate} Hz · '
      '${_audioConfig.numChannels} kanał(y) · ${_audioConfig.bitRate ~/ 1000} kbps',
      recordingId: id,
    );

    _stopwatch
      ..reset()
      ..start();
    _timer = Timer.periodic(const Duration(milliseconds: 250), (_) => notifyListeners());
    _isRecording = true;
    notifyListeners();
  }

  Future<void> stopRecording() async {
    if (!_isRecording || _isBusy) return;
    _isBusy = true;
    notifyListeners();

    try {
      final String? stoppedPath = await _recorder.stop();
      _timer?.cancel();
      _stopwatch.stop();
      _isRecording = false;

      final String? path = stoppedPath ?? _activeFilePath;
      if (path == null) {
        throw FileSystemException('Recorder did not return a file path.');
      }

      final File file = File(path);
      if (!await file.exists() || await file.length() == 0) {
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
        status: RecordingStatus.saved,
        type: CaptureType.audioRecording,
      );

      // Critical invariant: persist metadata only after the audio file exists.
      _recordings = <Recording>[saved, ..._recordings];
      await _repository.saveAll(_recordings);
      _logSink.log(
        'Plik zweryfikowany i zapisany · ${await file.length()} B',
        recordingId: saved.id,
      );

      // Processing is a separate step and starts only after durable save.
      // Enqueue for background processing and return; the drain loop runs the
      // job off the capture lock so it never blocks the next capture.
      await _enqueueProcessing(saved.id);
    } catch (exception) {
      _error = exception.toString();
      _logSink.log('Błąd zapisu nagrania: $exception', level: LogLevel.error);
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
      if (!await file.exists() || await file.length() == 0) {
        throw FileSystemException('Note file was not persisted correctly.', file.path);
      }

      final Recording saved = Recording(
        id: id,
        filePath: file.path,
        createdAt: DateTime.now(),
        durationMs: 0,
        status: RecordingStatus.saved,
        type: CaptureType.text,
        sourceMimeType: 'text/plain',
      );

      // Critical invariant: index the note only after the .txt exists on disk.
      _recordings = <Recording>[saved, ..._recordings];
      await _repository.saveAll(_recordings);
      _logSink.log(
        'Notatka zapisana · ${await file.length()} B',
        recordingId: saved.id,
      );

      // Enqueue for background processing and return; the drain loop runs the
      // job off the capture lock so it never blocks the next capture.
      await _enqueueProcessing(saved.id);
    } catch (exception) {
      _error = exception.toString();
      _logSink.log('Błąd zapisu notatki: $exception', level: LogLevel.error);
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
      await _repository.saveAll(_recordings);
      _logSink.log(
        'Zaimportowano plik · ${type.name} · ${await File(saved.filePath).length()} B',
        recordingId: saved.id,
      );

      // Enqueue for background processing and return; the drain loop runs the
      // job off the capture lock so it never blocks the next capture.
      await _enqueueProcessing(saved.id);
    } catch (exception) {
      _error = exception.toString();
      _logSink.log('Błąd importu pliku: $exception', level: LogLevel.error);
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
        throw FileSystemException('Plik nagrania nie istnieje.', recording.filePath);
      }

      await _player.stop();
      _playingId = id;
      notifyListeners();
      await _player.play(DeviceFileSource(recording.filePath));
    } catch (exception) {
      _playingId = null;
      _error = exception.toString();
      _logSink.log(
        'Odtwarzanie nieudane: $exception',
        level: LogLevel.error,
        recordingId: id,
      );
      notifyListeners();
    }
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
    _logSink.log('Ponowna próba przetwarzania.', level: LogLevel.warn, recordingId: id);
    await _enqueueProcessing(id);
  }

  /// Mark an already-persisted item `pendingTranscription`, add it to the
  /// processing queue, and kick the drain loop if it is idle. Returns once the
  /// queued state is persisted; the actual processing runs in the background.
  /// De-dupes so a double capture/retry cannot enqueue the same item twice.
  Future<void> _enqueueProcessing(String id) async {
    if (!_processingQueue.contains(id)) {
      _processingQueue.add(id);
    }
    await _update(
      id,
      (Recording item) => item.copyWith(
        status: RecordingStatus.pendingTranscription,
        clearError: true,
      ),
    );
    _logSink.log('W kolejce do przetwarzania.', recordingId: id);
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
    await _update(
      id,
      (Recording item) => item.copyWith(status: RecordingStatus.transcribing),
    );
    _logSink.log('Przetwarzanie uruchomione.', recordingId: id);

    final Recording recording = _recordings.firstWhere((Recording item) => item.id == id);
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
        'Przetwarzanie zakończone · ${transcript.length} znaków',
        recordingId: id,
      );
      // Deliberately last: the item is already `completed` and persisted, so a
      // refusing clipboard cannot undo a successful capture.
      await _copyToClipboard(recording.type, transcript, id);
    } catch (exception) {
      await _update(
        id,
        (Recording item) => item.copyWith(
          status: RecordingStatus.failed,
          error: exception.toString(),
        ),
      );
      _logSink.log(
        'Przetwarzanie nieudane: $exception',
        level: LogLevel.error,
        recordingId: id,
      );
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
      _logSink.log('Wynik skopiowany do schowka.', recordingId: id);
    } catch (exception) {
      _logSink.log(
        'Kopiowanie do schowka nieudane: $exception',
        level: LogLevel.warn,
        recordingId: id,
      );
    }
  }

  Future<void> _update(String id, Recording Function(Recording) transform) async {
    _recordings = _recordings
        .map((Recording item) => item.id == id ? transform(item) : item)
        .toList();
    await _repository.saveAll(_recordings);
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true; // lets an in-flight drain loop exit at the next boundary
    _timer?.cancel();
    _playerCompleteSub?.cancel();
    _player.dispose();
    _recorder.dispose();
    super.dispose();
  }
}
