import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

import '../../enrichment/domain/enrichment_context.dart';
import '../../enrichment/domain/enrichment_result.dart';
import '../../enrichment/domain/enrichment_service.dart';
import '../../logs/domain/log_event.dart';
import '../../processing/data/ocr_service.dart';
import '../../processing/data/video_audio_extractor.dart';
import '../../processing/data/video_poster_extractor.dart';
import '../../processing/domain/processor.dart';
import '../../processing/domain/processor_registry.dart';
import '../../settings/domain/audio_config.dart';
import '../../transcription/data/transcription_service.dart';
import '../data/media_importer.dart';
import '../data/media_picker.dart';
import '../data/recordings_repository.dart';
import '../data/revisions_repository.dart';
import '../domain/capture_category.dart';
import '../domain/capture_type.dart';
import '../domain/clipboard_sink.dart';
import '../domain/media_opener.dart';
import '../domain/recording.dart';
import '../domain/recording_revision.dart';
import '../domain/recording_tag.dart';

class RecordingsController extends ChangeNotifier {
  RecordingsController({
    required RecordingsRepository repository,
    required TranscriptionService transcriptionService,
    EnrichmentService enrichmentService = const DisabledEnrichmentService(),
    EnrichmentContextSource enrichmentContextSource =
        const EmptyEnrichmentContextSource(),
    OcrService ocrService = const DisabledOcrService(),
    VideoAudioExtractor videoAudioExtractor =
        const UnavailableVideoAudioExtractor(),
    VideoPosterExtractor videoPosterExtractor =
        const UnavailableVideoPosterExtractor(),
    AudioConfig audioConfig = AudioConfig.defaults,
    LogSink logSink = const NoopLogSink(),
    ClipboardSink clipboardSink = const NoopClipboardSink(),
    MediaOpener mediaOpener = const NoopMediaOpener(),
    RevisionsRepository? revisionsRepository,
    ProcessorRegistry? processorRegistry,
    MediaPicker? mediaPicker,
    AudioRecorder? recorder,
    AudioPlayer? player,
  }) : _repository = repository,
       _revisionsRepository = revisionsRepository,
       _transcriptionService = transcriptionService,
       _enrichmentService = enrichmentService,
       _enrichmentContextSource = enrichmentContextSource,
       _ocrService = ocrService,
       _videoAudioExtractor = videoAudioExtractor,
       _videoPosterExtractor = videoPosterExtractor,
       _audioConfig = audioConfig,
       _logSink = logSink,
       _clipboardSink = clipboardSink,
       _mediaOpener = mediaOpener,
       _mediaPicker = mediaPicker ?? const FilePickerMediaPicker(),
       _importer = MediaImporter(repository),
       _recorder = recorder ?? AudioRecorder(),
       _player = player ?? AudioPlayer() {
    // The default registry resolves the services lazily, so the Models/Config
    // tabs can keep swapping them without rebuilding the registry.
    _registry =
        processorRegistry ??
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

  /// Where the change history is appended. Null disables history entirely — the
  /// same optional-seam shape as [ClipboardSink] and [MediaOpener], so the
  /// pure-Dart tests that never touch a platform channel keep working unchanged
  /// and the shell is the one place that opts in.
  final RevisionsRepository? _revisionsRepository;

  /// Change history by capture id, newest first. Loaded once at [initialize]
  /// and kept in step by [_recordRevisions]; the file is append-only, so memory
  /// and disk can only ever diverge by a write that failed and was logged.
  Map<String, List<RecordingRevision>> _revisions =
      <String, List<RecordingRevision>>{};

  final LogSink _logSink;
  final ClipboardSink _clipboardSink;
  final MediaOpener _mediaOpener;
  final MediaPicker _mediaPicker;
  final MediaImporter _importer;
  late final ProcessorRegistry _registry;

  // All swappable at runtime from the Models/Config tabs. A swap only affects
  // work started afterwards; it never touches an in-flight pipeline.
  TranscriptionService _transcriptionService;
  EnrichmentService _enrichmentService;

  /// Resolves the user's profile and the item's project description. Not a
  /// `set` like the services below: the shell builds it once from callbacks
  /// that read the live controllers, so it is already current on every call.
  final EnrichmentContextSource _enrichmentContextSource;
  OcrService _ocrService;
  VideoAudioExtractor _videoAudioExtractor;
  VideoPosterExtractor _videoPosterExtractor;
  AudioConfig _audioConfig;

  final AudioRecorder _recorder;
  final AudioPlayer _player;
  StreamSubscription<void>? _playerCompleteSub;

  final Stopwatch _stopwatch = Stopwatch();
  final ValueNotifier<Duration> _elapsedTicker = ValueNotifier<Duration>(
    Duration.zero,
  );
  final ValueNotifier<double> _levelTicker = ValueNotifier<double>(0);
  StreamSubscription<Amplitude>? _amplitudeSub;
  Timer? _timer;
  List<Recording> _recordings = <Recording>[];
  bool _isRecording = false;
  bool _isBusy = false;
  String? _activeFilePath;
  String? _activeId;
  String? _playingId;

  /// Project inherited by captures created from this point onward. The
  /// projects controller owns selection; this is only its capture-time mirror.
  String? activeProjectId;
  String? _error;

  // Background processing queue. Capture enqueues an already-persisted item and
  // returns immediately; `_drainProcessingQueue` runs jobs one at a time off the
  // `_isBusy` capture lock, so a long job no longer blocks the next capture.
  final List<String> _processingQueue = <String>[];
  bool _isDraining = false;
  bool _disposed = false;
  String? _processingId; // the id currently running in the drain loop, if any
  Future<void>? _saveInFlight; // serializes saveAll (shared temp file)

  /// Set only when [initialize] found an index it could not read. While true
  /// every write is refused, because `_recordings` is then empty for a reason
  /// that has nothing to do with the queue being empty — and `saveAll` rewrites
  /// the *whole* index, so a single write in that state destroys the history it
  /// failed to load, leaving the source files orphaned.
  ///
  /// Deliberately defaults to false rather than "true until a load succeeds": a
  /// controller that was never initialized (every capture test, and the very
  /// first run before `recordings.json` exists) must still be able to persist.
  /// The flag encodes *"I know there is history I cannot see"*, which is a
  /// strictly narrower claim than *"I have not loaded"*.
  bool _indexUnreadable = false;

  /// Ids whose poster is being extracted right now. Poster extraction has two
  /// callers (the drain loop and the startup backfill) that both write the same
  /// `<id>.thumb.jpg`, so this is the mutex that stops two ffmpeg runs from
  /// racing onto one destination file.
  final Set<String> _postersInFlight = <String>{};

  /// The startup backfill, kept so [waitForProcessing] can await it. Null until
  /// [initialize] runs.
  Future<void>? _posterBackfill;

  /// Ids whose enrichment call is in flight right now — the second AI stage,
  /// which runs *after* the item is already `completed` and persisted.
  ///
  /// Deliberately in-memory only, and deliberately not a [RecordingStatus].
  /// That enum is written to `recordings.json`, so a new value would be a
  /// backward-compatibility change for a state that is never resumed: a kill in
  /// this window costs a title, and the item on disk is already whole. This is
  /// therefore a *view* fact, in the same class as [_postersInFlight].
  final Set<String> _enrichingIds = <String>{};

  List<Recording> get recordings => List<Recording>.unmodifiable(_recordings);

  /// What has been overwritten on this capture, newest first — the previous
  /// title a model replaced, the transcript a re-run threw away. Empty when
  /// nothing has ever been overwritten, which is the normal state of a capture
  /// that was processed once and left alone.
  List<RecordingRevision> revisionsFor(String id) =>
      List<RecordingRevision>.unmodifiable(
        _revisions[id] ?? const <RecordingRevision>[],
      );

  /// Whether the index could not be read at start-up. While true the controller
  /// refuses every write, so the queue is showing nothing rather than nothing
  /// being there — the UI must say so instead of looking empty.
  bool get isIndexUnreadable => _indexUnreadable;
  bool get isRecording => _isRecording;
  bool get isBusy => _isBusy;

  /// Whether the background processing loop is currently running a job.
  bool get isProcessing => _isDraining;

  /// Whether the enrichment model is reading this item's text right now, i.e.
  /// the window between the `completed` write and the title/category/summary
  /// landing. The queue card draws its scan line off this.
  ///
  /// Effectively never true on an install with no enrichment profile: the
  /// disabled service fails on its own microtask rather than on a network
  /// round trip, so the flag is set and cleared without a frame in between and
  /// the card never flickers a stage that is not configured.
  bool isEnriching(String id) => _enrichingIds.contains(id);

  /// Items currently in the processing pipeline — queued (`pendingTranscription`)
  /// plus the one running (`transcribing`). Derived from status so it always
  /// matches what the queue renders.
  int get pendingProcessingCount => _recordings
      .where(
        (Recording item) =>
            item.status == RecordingStatus.pendingTranscription ||
            item.status == RecordingStatus.transcribing,
      )
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

  /// Applied to the next poster extraction. A job already running keeps the
  /// extractor it started with.
  set videoPosterExtractor(VideoPosterExtractor value) {
    if (identical(_videoPosterExtractor, value)) return;
    _videoPosterExtractor = value;
  }

  /// Applied to the next capture. Never changes a recording already on disk.
  set audioConfig(AudioConfig value) {
    if (_audioConfig == value) return;
    _audioConfig = value;
  }

  Future<void> initialize() async {
    try {
      _recordings = await _repository.loadAll();
    } on IndexUnreadableException catch (exception) {
      // The index is there and cannot be read. Everything downstream — the
      // resume sweep, the poster backfill, any capture — would run against an
      // empty list, and the first `_update` would then persist that emptiness
      // over the history it failed to load. So: refuse to write, say so, stop.
      _indexUnreadable = true;
      _error =
          'Could not read the recordings index — writes are disabled to '
          'protect it. $exception';
      _logSink.log(_error!, level: LogLevel.error);
      notifyListeners();
      return;
    }
    _logSink.log('Loaded ${_recordings.length} captures from disk.');

    // Supporting evidence, never a precondition: a history that will not load
    // costs the edit sheet's HISTORY section, not the queue.
    try {
      _revisions =
          await _revisionsRepository?.load() ??
          <String, List<RecordingRevision>>{};
    } catch (exception) {
      _logSink.log(
        'Change history could not be read: $exception',
        level: LogLevel.warn,
      );
    }

    notifyListeners();

    // Resume jobs left non-terminal by a previous session (the app was killed
    // mid-processing). Their source is already on disk, so re-enqueuing is safe
    // and idempotent — the same persist-then-process invariant.
    final List<String> stuck = _recordings
        .where(
          (Recording item) =>
              item.status == RecordingStatus.pendingTranscription ||
              item.status == RecordingStatus.transcribing,
        )
        .map((Recording item) => item.id)
        .toList();
    for (final String id in stuck) {
      await _enqueueProcessing(id);
    }

    // Deliberately not awaited: posters are cosmetic, and shelling ffmpeg once
    // per video must never be something the first frame of the app waits for.
    _posterBackfill = _backfillPosters();
    unawaited(_posterBackfill!);
  }

  /// Bring source files with no index row back into the queue.
  ///
  /// The counterpart to the write guard: that stops history from being lost
  /// going forward, this recovers what an earlier build already lost. A capture
  /// is only ever *indexed* after its source file is written and verified, so a
  /// source with no row can only mean the row went missing — never that the
  /// capture was incomplete.
  ///
  /// **Called by the shell after [initialize], deliberately not from inside
  /// it.** It is the one operation here that reads the recordings *directory*
  /// rather than the index, so it is the one operation an in-memory repository
  /// fake cannot stand in for — leaving it in `initialize` made every widget
  /// test scan the developer's real capture folder. Keeping it a separate,
  /// explicit call also matches what it is: a repair, not part of loading.
  ///
  /// Best-effort, on the [_copyToClipboard] contract: it never touches an
  /// existing item, and it swallows its own errors into the log, so a failed
  /// scan costs a recovery rather than a start-up.
  Future<void> recoverOrphans() async {
    if (_indexUnreadable || _disposed) return;
    try {
      final List<Recording> orphans = await _repository.findOrphans(
        _recordings,
      );
      if (orphans.isEmpty || _disposed) return;

      _recordings = <Recording>[
        ..._recordings,
        ...orphans,
      ]..sort((Recording a, Recording b) => b.createdAt.compareTo(a.createdAt));
      await _persistAll();
      _logSink.log(
        'Recovered ${orphans.length} capture(s) with no index entry — '
        'restored as raw, re-run processing to get their text back.',
        level: LogLevel.warn,
      );
    } catch (exception) {
      _logSink.log('Orphan recovery failed: $exception', level: LogLevel.warn);
    }
  }

  /// Give every video on disk a poster, whether or not it is ever processed
  /// again.
  ///
  /// Without this the frame is only ever pulled from `_processOne`, so a clip
  /// ingested before posters existed — or one whose poster file was cleaned up
  /// — keeps the generic movie glyph until the user happens to hit retry, which
  /// there is no reason to do on an item that already succeeded.
  ///
  /// Best-effort like everything else on this path: [_extractPoster] swallows
  /// its own errors, an item that already has its frame on disk costs one
  /// `stat`, and the in-flight mutex keeps this off the drain loop's toes.
  Future<void> _backfillPosters() async {
    final List<String> videos = _recordings
        .where((Recording item) => item.type == CaptureType.video)
        .map((Recording item) => item.id)
        .toList();
    for (final String id in videos) {
      if (_disposed) return;
      await _extractPoster(id);
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
        throw FileSystemException(
          'Recording file was not persisted correctly.',
          path,
        );
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
        projectId: activeProjectId,
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
      _logSink.log(
        'Failed to save recording: $exception',
        level: LogLevel.error,
      );
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
        throw FileSystemException(
          'Note file was not persisted correctly.',
          file.path,
        );
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
        projectId: activeProjectId,
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
      final Recording imported = await _importer.importFile(
        id: id,
        type: type,
        source: picked.file,
        mimeType: picked.mimeType,
        createdAt: DateTime.now(),
      );
      final Recording saved = imported.copyWith(projectId: activeProjectId);

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

      final Recording recording = _recordings.firstWhere(
        (Recording item) => item.id == id,
      );
      final File file = File(recording.filePath);
      if (!await file.exists()) {
        throw FileSystemException(
          'Source file is missing.',
          recording.filePath,
        );
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
    await _update(
      id,
      (Recording item) => item.copyWith(transcript: trimmed),
      source: RevisionSource.user,
    );
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
      source: RevisionSource.user,
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
      (Recording item) =>
          item.copyWith(category: category, clearCategory: category == null),
      source: RevisionSource.user,
    );
    _logSink.log(
      category == null
          ? 'Category cleared.'
          : 'Category set \u00b7 ${category.name}',
      recordingId: id,
    );
  }

  Future<void> setProject(String id, String? projectId) async {
    final String? normalized = projectId?.trim();
    await _update(
      id,
      (Recording item) => item.copyWith(
        projectId: normalized,
        clearProjectId: normalized == null || normalized.isEmpty,
      ),
      source: RevisionSource.user,
    );
    _logSink.log(
      normalized == null || normalized.isEmpty
          ? 'Project cleared.'
          : 'Project assigned.',
      recordingId: id,
    );
  }

  /// Replaces the human-owned layer while preserving AI suggestions. Values
  /// are normalized and de-duplicated; a human value wins an AI duplicate.
  Future<void> setTags(String id, Iterable<String> tags) async {
    // Authoritative, not additive: the list that arrives is the list that is
    // stored. This is what lets the user delete a tag the model proposed —
    // under the old provenance model the editor could only rewrite its own
    // layer, so a model tag was undeletable by construction.
    final List<String> normalized = RecordingTags.normalize(tags);
    await _update(
      id,
      (Recording item) => item.copyWith(tags: normalized),
      source: RevisionSource.user,
    );
    _logSink.log(
      normalized.isEmpty ? 'Tags cleared.' : 'Tags updated.',
      recordingId: id,
    );
  }

  Future<void> toggleProcessed(String id) async {
    final Recording recording = _recordings.firstWhere(
      (Recording item) => item.id == id,
    );
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
    // The startup poster backfill runs unawaited off `initialize`, so it is part
    // of "the background work has settled" for a test's purposes.
    await _posterBackfill;
    int guard = 0;
    while ((_isDraining ||
            pendingProcessingCount > 0 ||
            _postersInFlight.isNotEmpty) &&
        guard++ < 10000) {
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

      final Recording recording = _recordings.firstWhere(
        (Recording item) => item.id == id,
      );
      // Pin the processor for this job: a runtime swap (Models tab) during the
      // await gaps above must not redirect a job that already started.
      final Processor processor = _registry.forType(recording.type);

      // Deliberately outside the try below, and before the processor runs. A
      // video whose transcription fails — no active profile, an audio codec
      // ffmpeg cannot read — is exactly the item the user most needs to
      // recognise in the queue, so the poster must not be collateral damage of
      // that failure. The reverse holds too: `_extractPoster` swallows
      // everything, so a missing ffmpeg costs a thumbnail and never a status.
      await _extractPoster(recording.id);

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

  /// Pull a poster frame off a video so the queue can show what the clip is.
  ///
  /// Best-effort by construction, the same contract as [_enrich] and
  /// [_copyToClipboard]: it never touches `status`, it swallows every error
  /// into the log, and the poster it writes is a derived artifact the app is
  /// free to lose. Non-video items are a no-op, and so is a video that already
  /// has a poster still on disk — a retry must not re-shell ffmpeg for a frame
  /// that has not changed. A `thumbPath` whose file has since gone *does*
  /// re-extract: the path is only ever a claim that a frame was written.
  ///
  /// Takes an id rather than a [Recording] because both callers hold a snapshot
  /// the other one can invalidate, and the guards below are only worth anything
  /// when they read the item as it is now.
  Future<void> _extractPoster(String id) async {
    final int index = _recordings.indexWhere((Recording item) => item.id == id);
    if (index < 0) return;
    final Recording item = _recordings[index];
    if (item.type != CaptureType.video) return;

    final String? existing = item.thumbPath;
    if (existing != null && await File(existing).exists()) return;

    // Claimed synchronously, before the first await below, so this is a real
    // mutex between the drain loop and the startup backfill rather than a
    // narrower race onto the same `<id>.thumb.jpg`.
    if (!_postersInFlight.add(id)) return;
    try {
      final File destination = await _repository.createSourceFile(
        item.id,
        'thumb.jpg',
      );
      final File poster = await _videoPosterExtractor.extractPoster(
        File(item.filePath),
        destination,
      );
      if (_disposed) return;
      await _update(
        item.id,
        (Recording current) => current.copyWith(thumbPath: poster.path),
      );
      _logSink.log('Poster frame extracted.', recordingId: item.id);
    } catch (exception) {
      _logSink.log(
        'Poster extraction failed: $exception',
        level: LogLevel.warn,
        recordingId: item.id,
      );
    } finally {
      _postersInFlight.remove(id);
    }
  }

  /// Hand the item's source file to the platform's own player/viewer. Used for
  /// video, which has no in-app player on the desktop targets this ships on.
  ///
  /// Deliberately not gated on [CaptureType] here — the card decides what is
  /// openable, exactly as it does for [togglePlayback] — but a missing source
  /// is refused, because handing a dead path to `xdg-open` would either do
  /// nothing or raise someone else's error dialog.
  Future<void> openSource(String id) async {
    _error = null;
    try {
      final Recording recording = _recordings.firstWhere(
        (Recording item) => item.id == id,
      );
      if (!await File(recording.filePath).exists()) {
        throw FileSystemException(
          'Source file is missing.',
          recording.filePath,
        );
      }

      await _mediaOpener.open(recording.filePath);
      _logSink.log('Opened source externally.', recordingId: id);
      // The `_error = null` above only reaches the banner if something tells
      // the view to rebuild. `togglePlayback` gets that for free from the
      // `_playingId` notify; an external open has no state of its own, so
      // without this a failed open stays on screen after the retry that worked.
      notifyListeners();
    } catch (exception) {
      _error = exception.toString();
      _logSink.log(
        'Opening the source failed: $exception',
        level: LogLevel.error,
        recordingId: id,
      );
      notifyListeners();
    }
  }

  /// Hand freshly derived text to the clipboard so a clipboard manager records
  /// it as a history entry. Text notes are skipped: their processor output is
  /// the body the user just typed, so nothing was derived worth handing back.
  ///
  /// Swallows every error, on the same rule as logging — this runs after the
  /// item is already `completed` on disk and must never fail the pipeline.
  Future<void> _copyToClipboard(
    CaptureType type,
    String text,
    String id,
  ) async {
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
    // Resolved *before* the ANALYZING flag goes up, and that ordering is
    // load-bearing. Looking the context up can touch the filesystem — a
    // project's CLAUDE.md — and raising the flag first would put a scan line on
    // screen for an install whose enrichment is disabled, which is the one case
    // the disabled service takes care to fail without ever building a frame.
    final EnrichmentContext context = await _resolveEnrichmentContext(id);
    if (_disposed) return;
    // Marked before the call and cleared in `finally`, so the card's scan line
    // cannot outlive the request — including on the throwing paths below, which
    // are the common case until a profile is configured.
    _enrichingIds.add(id);
    if (!_disposed) notifyListeners();
    try {
      final EnrichmentResult result = await _enrichmentService.enrich(
        text,
        context: context,
      );
      if (_disposed) return;
      await _update(
        id,
        (Recording item) => item.copyWith(
          // User-editable fields are fill-only: a retry must not undo a manual
          // correction. Clearing a field asks enrichment to fill it again.
          title: (item.title ?? '').trim().isEmpty ? result.title : null,
          category: item.category ?? result.category,
          summary: result.summary,
          // Fill-only, like `title` and `category`, now that a tag carries no
          // owner: with nothing marking which tags came from a model, a refresh
          // could only refresh *all* of them, and a re-run would keep
          // resurrecting tags the user had deleted. Clearing the list is how
          // you ask for a fresh set. Re-resolving `item` inside the update is
          // what makes an edit landing mid-request win over this.
          tags: item.tags.isEmpty ? RecordingTags.normalize(result.tags) : null,
        ),
        // The reason this feature exists: `summary` has no editor and is
        // refreshed wholesale on every re-run, so without a record the previous
        // one is simply gone.
        source: RevisionSource.enrichment,
      );
      // The context source is named in the log because it is otherwise
      // invisible: a title that improved after a CLAUDE.md was written is not
      // something the queue can show, and this is the only place that says
      // which file the model was actually given.
      final String source = context.projectSource == null
          ? ''
          : ' \u00b7 context: ${context.projectSource}';
      _logSink.log(
        'Enriched \u00b7 ${result.category.name}$source',
        recordingId: id,
      );
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
    } finally {
      _enrichingIds.remove(id);
      if (!_disposed) notifyListeners();
    }
  }

  /// Resolve the user profile and the item's project description.
  ///
  /// Swallows everything into the log under the `ClipboardSink` contract: a
  /// repository that has been moved, renamed or unmounted must cost a worse
  /// title, never the enrichment — and certainly never the capture.
  Future<EnrichmentContext> _resolveEnrichmentContext(String id) async {
    final int index = _recordings.indexWhere((Recording item) => item.id == id);
    final String? projectId = index < 0 ? null : _recordings[index].projectId;
    try {
      return await _enrichmentContextSource.contextFor(projectId);
    } catch (exception) {
      _logSink.log(
        'Enrichment context unavailable: $exception',
        level: LogLevel.warn,
        recordingId: id,
      );
      return EnrichmentContext.none;
    }
  }

  /// Diff the five user-meaningful fields and append what actually changed.
  ///
  /// Only these five: `status`, `error` and `thumbPath` are pipeline mechanics
  /// that already have the Logs tab, and recording them here would bury the two
  /// questions this feature exists to answer — *what did the model rename this
  /// to, and what did the transcript say before the re-run* — under a wall of
  /// `saved → transcribing → completed`.
  ///
  /// **A change out of an empty value is not recorded.** Filling a blank title
  /// or writing a transcript for the first time overwrites nothing, so there is
  /// nothing to preserve; the current value already lives in `recordings.json`.
  /// This is also what keeps the file small: the common case — every capture's
  /// first transcript — never reaches it, and only a re-run that genuinely
  /// replaces text pays for a copy.
  ///
  /// Best-effort on the [_copyToClipboard] contract: a failed history write is
  /// logged and swallowed, never allowed to fail the capture it describes.
  Future<void> _recordRevisions(
    Recording before,
    Recording after,
    RevisionSource source,
  ) async {
    final RevisionsRepository? repository = _revisionsRepository;
    if (repository == null) return;

    final List<RecordingRevision> changes = <RecordingRevision>[];
    void diff(String field, String? from, String? to) {
      if (from == to) return;
      // Nothing was overwritten — see the doc comment above.
      if (from == null || from.isEmpty) return;
      changes.add(
        RecordingRevision(
          recordingId: after.id,
          at: DateTime.now(),
          field: field,
          from: RecordingRevision.truncate(from),
          to: RecordingRevision.truncate(to),
          source: source,
        ),
      );
    }

    diff('title', before.title, after.title);
    diff('category', before.category?.name, after.category?.name);
    diff('summary', before.summary, after.summary);
    diff('tags', before.tags.join(', '), after.tags.join(', '));
    diff('transcript', before.transcript, after.transcript);
    if (changes.isEmpty) return;

    // Update the in-memory view first so the edit sheet shows the entry even if
    // the append below fails — the history is then correct for this session and
    // merely incomplete on disk, rather than invisible in both.
    _revisions
        .putIfAbsent(after.id, () => <RecordingRevision>[])
        .insertAll(0, changes);
    try {
      await repository.append(changes);
    } catch (exception) {
      _logSink.log(
        'Change history not written: $exception',
        level: LogLevel.warn,
        recordingId: after.id,
      );
    }
  }

  Future<void> _update(
    String id,
    Recording Function(Recording) transform, {
    RevisionSource source = RevisionSource.processor,
  }) async {
    // Captured before the map so the diff below compares the same item across
    // the transform. Every mutation in this class funnels through here, which
    // is what makes the history impossible to bypass by adding a new setter.
    final int index = _recordings.indexWhere((Recording item) => item.id == id);
    final Recording? before = index < 0 ? null : _recordings[index];

    _recordings = _recordings
        .map((Recording item) => item.id == id ? transform(item) : item)
        .toList();

    // Persist even after dispose: the drain can be mid-job when the shell tears
    // the page down, and the status it just computed still belongs on disk.
    await _persistAll();

    // Deliberately *after* the persist, never before. `_persistAll` can refuse
    // (an unreadable index) or throw (a full disk), and a history entry for a
    // change that never reached `recordings.json` would describe a state no
    // file ever held. Recording it here means the history can only ever lag the
    // index, never lead it.
    if (before != null) {
      await _recordRevisions(before, _recordings[index], source);
    }
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
    // The one place a refusal is worth more than a write. Every mutation in
    // this class funnels through here, so this single guard is what makes the
    // "unreadable index is never overwritten" promise unbypassable.
    if (_indexUnreadable) {
      _logSink.log(
        'Write refused — the recordings index could not be read; '
        'existing history is left untouched.',
        level: LogLevel.error,
      );
      return;
    }
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
