import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

import '../../logs/domain/log_event.dart';
import '../../settings/domain/audio_config.dart';
import '../../transcription/data/transcription_service.dart';
import '../data/recordings_repository.dart';
import '../domain/recording.dart';

class RecordingsController extends ChangeNotifier {
  RecordingsController({
    required RecordingsRepository repository,
    required TranscriptionService transcriptionService,
    AudioConfig audioConfig = AudioConfig.defaults,
    LogSink logSink = const NoopLogSink(),
    AudioRecorder? recorder,
    AudioPlayer? player,
  })  : _repository = repository,
        _transcriptionService = transcriptionService,
        _audioConfig = audioConfig,
        _logSink = logSink,
        _recorder = recorder ?? AudioRecorder(),
        _player = player ?? AudioPlayer() {
    // Reset the "now playing" marker when a clip finishes on its own.
    _playerCompleteSub = _player.onPlayerComplete.listen((_) {
      _playingId = null;
      notifyListeners();
    });
  }

  final RecordingsRepository _repository;
  final LogSink _logSink;

  // Both are swappable at runtime from the Models/Config tabs. A swap only
  // affects work started afterwards; it never touches an in-flight pipeline.
  TranscriptionService _transcriptionService;
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
  String? _playingId;
  String? _error;

  List<Recording> get recordings => List<Recording>.unmodifiable(_recordings);
  bool get isRecording => _isRecording;
  bool get isBusy => _isBusy;
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

  /// Applied to the next capture. Never changes a recording already on disk.
  set audioConfig(AudioConfig value) {
    if (_audioConfig == value) return;
    _audioConfig = value;
  }

  Future<void> initialize() async {
    _recordings = await _repository.loadAll();
    _logSink.log('Wczytano ${_recordings.length} nagrań z dysku.');
    notifyListeners();
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

      final String id = file.uri.pathSegments.last.replaceAll('.m4a', '');
      final Recording saved = Recording(
        id: id,
        filePath: path,
        createdAt: DateTime.now(),
        durationMs: _stopwatch.elapsedMilliseconds,
        status: RecordingStatus.saved,
      );

      // Critical invariant: persist metadata only after the audio file exists.
      _recordings = <Recording>[saved, ..._recordings];
      await _repository.saveAll(_recordings);
      _logSink.log(
        'Plik zweryfikowany i zapisany · ${await file.length()} B',
        recordingId: saved.id,
      );

      // Transcription is a separate step and starts only after durable save.
      await _markAndTranscribe(saved.id);
    } catch (exception) {
      _error = exception.toString();
      _logSink.log('Błąd zapisu nagrania: $exception', level: LogLevel.error);
    } finally {
      _isBusy = false;
      _activeFilePath = null;
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

  Future<void> retryTranscription(String id) async {
    if (_isBusy) return;
    _isBusy = true;
    _logSink.log('Ponowna próba transkrypcji.', level: LogLevel.warn, recordingId: id);
    notifyListeners();
    try {
      await _markAndTranscribe(id);
    } finally {
      _isBusy = false;
      notifyListeners();
    }
  }

  Future<void> _markAndTranscribe(String id) async {
    await _update(
      id,
      (Recording item) => item.copyWith(
        status: RecordingStatus.pendingTranscription,
        clearError: true,
      ),
    );

    _logSink.log('W kolejce do transkrypcji.', recordingId: id);

    await _update(
      id,
      (Recording item) => item.copyWith(status: RecordingStatus.transcribing),
    );
    _logSink.log('Transkrypcja uruchomiona.', recordingId: id);

    final Recording recording = _recordings.firstWhere((Recording item) => item.id == id);
    try {
      final String transcript = await _transcriptionService.transcribe(File(recording.filePath));
      await _update(
        id,
        (Recording item) => item.copyWith(
          status: RecordingStatus.completed,
          transcript: transcript,
          clearError: true,
        ),
      );
      _logSink.log(
        'Transkrypcja gotowa · ${transcript.length} znaków',
        recordingId: id,
      );
    } catch (exception) {
      await _update(
        id,
        (Recording item) => item.copyWith(
          status: RecordingStatus.failed,
          error: exception.toString(),
        ),
      );
      _logSink.log(
        'Transkrypcja nieudana: $exception',
        level: LogLevel.error,
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
    _timer?.cancel();
    _playerCompleteSub?.cancel();
    _player.dispose();
    _recorder.dispose();
    super.dispose();
  }
}
