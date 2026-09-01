import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../domain/local_transcription_engine.dart';
import 'audio_decoder.dart';

// The three functions `native/augustyniak_whisper.h` exposes. Nothing else
// crosses this boundary — see that header for why the whisper.cpp API is not
// bound directly.
typedef _TranscribeNative =
    Int32 Function(
      Pointer<Utf8> modelPath,
      Pointer<Float> pcm,
      Int32 sampleCount,
      Pointer<Utf8> language,
      Int32 threads,
      Pointer<Pointer<Utf8>> outText,
    );
typedef _TranscribeDart =
    int Function(
      Pointer<Utf8> modelPath,
      Pointer<Float> pcm,
      int sampleCount,
      Pointer<Utf8> language,
      int threads,
      Pointer<Pointer<Utf8>> outText,
    );
typedef _StringFreeNative = Void Function(Pointer<Utf8> text);
typedef _StringFreeDart = void Function(Pointer<Utf8> text);
typedef _AbiVersionNative = Pointer<Utf8> Function();
typedef _AbiVersionDart = Pointer<Utf8> Function();

/// Runs whisper.cpp in this process, through the C shim in `native/`.
///
/// **Availability is decided once, at construction, and never per capture** —
/// the rule [LocalTranscriptionEngine.isAvailable] exists for. Opening the
/// library is the only way to find out whether this build shipped one, so it
/// happens here and the answer is cached; a Models tab that had to make a call
/// before it knew whether a section exists is a section that flickers.
class WhisperFfiEngine implements LocalTranscriptionEngine {
  WhisperFfiEngine({AudioDecoder? decoder, String? libraryPath})
    : _decoder = decoder ?? const UnavailableAudioDecoder(),
      _libraryPath = libraryPath ?? defaultLibraryPath() {
    _probe();
  }

  final AudioDecoder _decoder;
  final String _libraryPath;

  String? _reason;

  /// The platforms whose build actually produces the shim today.
  ///
  /// Listed rather than inferred from "can I open it": a platform with no
  /// native build should say so in the words a user can act on, and a failed
  /// `dlopen` on a platform that was never meant to have one reports a missing
  /// file instead.
  static bool get _platformHasNativeBuild =>
      Platform.isLinux || Platform.isAndroid || Platform.isMacOS;

  /// Where the bundle puts the shim on each platform that ships one.
  ///
  /// Resolved relative to the running executable rather than by bare name: a
  /// bare `dlopen` searches the system loader path, and a stray library of the
  /// same name found there is a worse outcome than not finding one at all.
  static String defaultLibraryPath() {
    final String executable = File(Platform.resolvedExecutable).parent.path;
    if (Platform.isLinux) {
      return '$executable/lib/libaugustyniak_whisper.so';
    }
    if (Platform.isMacOS) {
      return '$executable/../Frameworks/libaugustyniak_whisper.dylib';
    }
    if (Platform.isWindows) return '$executable\\augustyniak_whisper.dll';
    // Android packages it under `lib/<abi>/` in the APK, where the loader
    // finds it by bare name — the one platform where a bare name is right,
    // because the APK's library path is the app's own and not a shared system
    // one. iOS links it into the application binary instead and will need
    // `DynamicLibrary.process()` rather than a path at all.
    return 'libaugustyniak_whisper.so';
  }

  void _probe() {
    if (!_platformHasNativeBuild) {
      // Honest rather than optimistic: the remaining platforms have no native
      // build yet, and claiming otherwise would fail once per capture instead
      // of saying so once in the Models tab.
      _reason =
          'On-device transcription is not built for '
          '${Platform.operatingSystem} yet. Use a remote profile here.';
      return;
    }
    if (!_decoder.isAvailable) {
      // The engine is only as available as the decoder feeding it: a model
      // handed the AAC container unchanged does not fail, it returns confident
      // nonsense — the quietest failure this path could have.
      _reason =
          'On-device transcription needs an audio decoder this build does not '
          'have. Install ffmpeg, or use a remote profile here.';
      return;
    }
    try {
      final DynamicLibrary library = DynamicLibrary.open(_libraryPath);
      // Proves it is *our* shim rather than an unrelated library that happens
      // to share the file name.
      final _AbiVersionDart version = library
          .lookupFunction<_AbiVersionNative, _AbiVersionDart>(
            'aug_whisper_abi_version',
          );
      version().toDartString();
      _reason = null;
    } catch (exception) {
      // Two different situations reach here and the message has to serve
      // both: a build that ships the library and cannot open it (a broken or
      // unsigned artifact), and one whose packaging step has not been written
      // yet. Naming the path is what separates them for whoever reads it.
      _reason =
          'The on-device speech library could not be loaded from '
          '$_libraryPath. This build may not ship it yet. ($exception)';
    }
  }

  @override
  bool get isAvailable => _reason == null;

  @override
  String? get unavailableReason => _reason;

  @override
  Future<String> transcribe({
    required File audio,
    required String modelPath,
    String? language,
  }) async {
    final String? reason = _reason;
    if (reason != null) throw LocalTranscriptionUnavailableException(reason);

    if (!await File(modelPath).exists()) {
      throw FileSystemException('Model file is missing.', modelPath);
    }

    final DecodedAudio decoded = await _decoder.decodeToPcm(audio);
    try {
      final Uint8List bytes = await decoded.file.readAsBytes();
      // **Off the main isolate, always.** A minute of audio on a small model is
      // seconds of solid CPU, and this call does not yield: run it here and the
      // UI stops painting mid-capture, including the queue that reports the
      // capture it is working on.
      return await Isolate.run(
        () => _transcribeBlocking(
          libraryPath: _libraryPath,
          modelPath: modelPath,
          pcmBytes: bytes,
          language: language,
        ),
      );
    } finally {
      await decoded.dispose();
    }
  }
}

/// The blocking call, in whatever isolate runs it.
///
/// A top-level function taking only plain data: an `Isolate.run` closure may
/// capture nothing that cannot cross an isolate boundary, and a
/// `DynamicLibrary` cannot. Opening it again here costs a `dlopen` of a library
/// the process already has mapped.
String _transcribeBlocking({
  required String libraryPath,
  required String modelPath,
  required Uint8List pcmBytes,
  required String? language,
}) {
  final DynamicLibrary library = DynamicLibrary.open(libraryPath);
  final _TranscribeDart transcribe = library
      .lookupFunction<_TranscribeNative, _TranscribeDart>(
        'aug_whisper_transcribe',
      );
  final _StringFreeDart stringFree = library
      .lookupFunction<_StringFreeNative, _StringFreeDart>(
        'aug_whisper_string_free',
      );

  final int sampleCount = pcmBytes.lengthInBytes ~/ 4;
  if (sampleCount == 0) {
    throw const LocalTranscriptionUnavailableException(
      'The decoded audio was empty.',
    );
  }

  final Pointer<Float> pcm = calloc<Float>(sampleCount);
  final Pointer<Utf8> model = modelPath.toNativeUtf8();
  final Pointer<Utf8> lang = (language == null || language.trim().isEmpty)
      ? nullptr
      : language.trim().toNativeUtf8();
  final Pointer<Pointer<Utf8>> out = calloc<Pointer<Utf8>>();
  try {
    // One copy, through a typed view rather than a per-sample loop: the buffer
    // is 16,000 floats per second of audio.
    pcm
        .asTypedList(sampleCount)
        .setAll(0, pcmBytes.buffer.asFloat32List(0, sampleCount));

    final int code = transcribe(
      model,
      pcm,
      sampleCount,
      lang,
      _threadCount(),
      out,
    );
    final Pointer<Utf8> answer = out.value;
    // The shim guarantees a string either way — the transcript, or the reason.
    final String text = answer == nullptr ? '' : answer.toDartString();
    if (answer != nullptr) stringFree(answer);
    if (code != 0) {
      throw LocalTranscriptionUnavailableException(
        text.isEmpty ? 'On-device transcription failed.' : text,
      );
    }
    return text.trim();
  } finally {
    calloc.free(pcm);
    calloc.free(model);
    if (lang != nullptr) calloc.free(lang);
    calloc.free(out);
  }
}

/// Leaves the machine usable while a capture transcribes. All of them would be
/// faster and would also stall the desktop it is running on.
int _threadCount() {
  final int cores = Platform.numberOfProcessors;
  if (cores <= 2) return 1;
  return (cores ~/ 2).clamp(2, 8);
}
