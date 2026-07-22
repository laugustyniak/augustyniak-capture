import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

import '../../transcription/data/transcription_service.dart';
import '../data/recordings_repository.dart';
import '../domain/recording.dart';

class RecordingsController extends ChangeNotifier {
  RecordingsController({
    required RecordingsRepository repository,
    required TranscriptionService transcriptionService,
    AudioRecorder? recorder,
  })  : _repository = repository,
        _transcriptionService = transcriptionService,
        _recorder = recorder ?? AudioRecorder();

  final RecordingsRepository _repository;
  final TranscriptionService _transcriptionService;
  final AudioRecorder _recorder;

  final Stopwatch _stopwatch = Stopwatch();
  Timer? _timer;
  List<Recording> _recordings = <Recording>[];
  bool _isRecording = false;
  bool _isBusy = false;
  String? _activeFilePath;
  String? _error;

  List<Recording> get recordings => List<Recording>.unmodifiable(_recordings);
  bool get isRecording => _isRecording;
  bool get isBusy => _isBusy;
  Duration get elapsed => _stopwatch.elapsed;
  String? get error => _error;

  Future<void> initialize() async {
    _recordings = await _repository.loadAll();
    notifyListeners();
  }

  Future<void> startRecording() async {
    if (_isRecording || _isBusy) return;
    _error = null;

    final bool allowed = await _recorder.hasPermission();
    if (!allowed) {
      _error = 'Brak uprawnienia do mikrofonu.';
      notifyListeners();
      return;
    }

    final String id = const Uuid().v4();
    final File audioFile = await _repository.createAudioFile(id);
    _activeFilePath = audioFile.path;

    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        sampleRate: 16000,
        numChannels: 1,
        bitRate: 64000,
      ),
      path: audioFile.path,
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

      // Transcription is a separate step and starts only after durable save.
      await _markAndTranscribe(saved.id);
    } catch (exception) {
      _error = exception.toString();
    } finally {
      _isBusy = false;
      _activeFilePath = null;
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

    await _update(
      id,
      (Recording item) => item.copyWith(status: RecordingStatus.transcribing),
    );

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
    } catch (exception) {
      await _update(
        id,
        (Recording item) => item.copyWith(
          status: RecordingStatus.failed,
          error: exception.toString(),
        ),
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
    _recorder.dispose();
    super.dispose();
  }
}
