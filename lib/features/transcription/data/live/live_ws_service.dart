import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../domain/live_transcription.dart';

/// Per-session text state a provider's [LiveWsService.handle] mutates.
///
/// Kept apart from the service so one service can open many sessions and a
/// provider subclass stays free of per-take fields.
class LiveSessionState {
  LiveSessionState(this.joiner);

  /// Put between committed segments. Providers whose tokens carry their own
  /// spaces use `''`.
  final String joiner;

  String committed = '';
  String partial = '';

  /// Set once `finish()` has begun; providers read it to recognise their
  /// end-of-stream reply.
  bool finishing = false;

  /// A provider-reported fatal error. The base class ends the session.
  String? error;

  /// Provider-owned bookkeeping (counters, per-item partials).
  final Map<String, Object?> scratch = <String, Object?>{};

  void commit(String text) {
    if (text.trim().isEmpty) return;
    committed = committed.isEmpty ? text : '$committed$joiner$text';
  }

  /// Everything heard so far, unfinalised partial included.
  String get full {
    final String tail = partial;
    if (tail.trim().isEmpty) return committed.trim();
    return (committed.isEmpty ? tail : '$committed$joiner$tail').trim();
  }
}

/// A WebSocket speech provider. This class owns the connection, buffering,
/// failure and finish mechanics; a subclass states only its wire protocol.
///
/// **Nothing here may fail a capture.** The audio is already being written to
/// disk by the caller; a dead socket turns into `LiveTranscript(failed: true)`
/// and `finish()` answering with what was heard, and the recording falls back
/// to the batch pipeline.
abstract class LiveWsService implements LiveTranscriptionService {
  LiveWsService({
    required this.endpoint,
    this.bearerToken,
    this.model,
    this.language,
    this.connectTimeout = const Duration(seconds: 10),
    this.finishTimeout = const Duration(seconds: 8),
    this.maxBufferedSeconds = 30,
  });

  final Uri endpoint;
  final String? bearerToken;
  final String? model;
  final String? language;
  final Duration connectTimeout;

  /// How long `finish()` waits for the provider's final signal.
  final Duration finishTimeout;

  /// Audio held while the socket is still opening; the oldest is dropped.
  final int maxBufferedSeconds;

  @override
  bool get isAvailable => true;

  @override
  int get sampleRate => 16000;

  /// Joins committed segments; `''` for providers whose tokens carry spaces.
  String get joiner => ' ';

  /// Idle gap after which [keepAliveMessage] is sent. Null disables it.
  Duration? get keepAliveInterval => null;
  Object? get keepAliveMessage => null;

  // --- the protocol a provider implements ---------------------------------

  Uri buildUri();

  Map<String, String> headers();

  /// Text (`String`) or binary (`Uint8List`) frames sent right after connect.
  List<Object> openMessages();

  /// Frames carrying one PCM chunk.
  List<Object> encodeAudio(Uint8List chunk, LiveSessionState state);

  /// Apply one decoded JSON message to [state]. Set `state.error` to end the
  /// session as failed.
  void handle(Map<String, dynamic> message, LiveSessionState state);

  /// Frames that make the provider flush; may be empty.
  List<Object> finishMessages(LiveSessionState state);

  /// Checked right after [finishMessages] was sent: true when the provider owes
  /// nothing more, so `finish()` need not wait for [isTerminal].
  bool isDrained(LiveSessionState state) => false;

  /// Whether [message] is the provider's answer to the end-of-stream request.
  /// The socket closing is always terminal too.
  bool isTerminal(Map<String, dynamic> message, LiveSessionState state);

  @override
  LiveTranscriptionSession start() => LiveWsSession(this);
}

class LiveWsSession implements LiveTranscriptionSession {
  LiveWsSession(this._service) : _state = LiveSessionState(_service.joiner) {
    _maxBufferedBytes = _service.sampleRate * 2 * _service.maxBufferedSeconds;
    _connected = _connect();
    final Duration? interval = _service.keepAliveInterval;
    if (interval != null) {
      _keepAlive = Timer.periodic(interval, (_) => _onKeepAlive());
    }
  }

  final LiveWsService _service;
  final LiveSessionState _state;
  final StreamController<LiveTranscript> _updates =
      StreamController<LiveTranscript>.broadcast();
  final Queue<Uint8List> _pending = Queue<Uint8List>();
  final Completer<void> _terminal = Completer<void>();

  late final int _maxBufferedBytes;
  late final Future<bool> _connected;
  int _pendingBytes = 0;
  WebSocket? _socket;
  Timer? _keepAlive;
  bool _open = false;
  bool _dead = false;
  bool _closed = false;
  bool _sentSinceTick = false;

  @override
  Stream<LiveTranscript> get updates => _updates.stream;

  Future<bool> _connect() async {
    try {
      final WebSocket socket = await WebSocket.connect(
        _service.buildUri().toString(),
        headers: _service.headers(),
      ).timeout(_service.connectTimeout);
      if (_closed || _dead) {
        unawaited(_closeSocket(socket));
        return false;
      }
      _socket = socket;
      socket.listen(
        _onData,
        onError: (Object _) => _die(),
        onDone: _die,
        cancelOnError: true,
      );
      _open = true;
      _send(_service.openMessages());
      while (_pending.isNotEmpty) {
        _sendAudio(_pending.removeFirst());
      }
      _pendingBytes = 0;
      return true;
    } catch (_) {
      _die();
      return false;
    }
  }

  void _onData(dynamic data) {
    if (data is! String) return;
    final Map<String, dynamic> message;
    try {
      final dynamic decoded = jsonDecode(data);
      if (decoded is! Map<String, dynamic>) return;
      message = decoded;
    } catch (_) {
      return;
    }
    try {
      _service.handle(message, _state);
    } catch (_) {
      return;
    }
    if (_state.error != null) {
      _die();
      return;
    }
    _emit();
    if (_state.finishing && _service.isTerminal(message, _state)) {
      _finishTerminal();
    }
  }

  void _emit({bool failed = false}) {
    if (_updates.isClosed) return;
    _updates.add(
      LiveTranscript(
        committed: _state.committed,
        partial: failed ? '' : _state.partial,
        failed: failed,
      ),
    );
  }

  void _finishTerminal() {
    if (!_terminal.isCompleted) _terminal.complete();
  }

  /// The socket died or the provider reported a fatal error.
  void _die() {
    if (_dead) return;
    _dead = true;
    _open = false;
    _keepAlive?.cancel();
    _pending.clear();
    _pendingBytes = 0;
    if (!_closed && !_state.finishing) _emit(failed: true);
    _finishTerminal();
    final WebSocket? socket = _socket;
    if (socket != null) unawaited(_closeSocket(socket));
  }

  Future<void> _closeSocket(WebSocket socket) async {
    try {
      await socket.close(WebSocketStatus.normalClosure);
    } catch (_) {}
  }

  void _send(List<Object> frames) {
    final WebSocket? socket = _socket;
    if (socket == null || !_open) return;
    try {
      for (final Object frame in frames) {
        socket.add(frame as dynamic);
      }
      _sentSinceTick = true;
    } catch (_) {
      _die();
    }
  }

  void _sendAudio(Uint8List chunk) {
    try {
      _send(_service.encodeAudio(chunk, _state));
    } catch (_) {
      // An encoder bug must not reach the capture.
    }
  }

  void _onKeepAlive() {
    if (!_open || _state.finishing) return;
    final Object? message = _service.keepAliveMessage;
    if (message == null) return;
    if (_sentSinceTick) {
      _sentSinceTick = false;
      return;
    }
    _send(<Object>[message]);
    _sentSinceTick = false;
  }

  @override
  void addAudio(Uint8List pcm16le) {
    try {
      if (_dead || _closed || _state.finishing || pcm16le.isEmpty) return;
      if (_open) {
        _sendAudio(pcm16le);
        return;
      }
      // Copy: the recorder may reuse its buffer.
      _pending.add(Uint8List.fromList(pcm16le));
      _pendingBytes += pcm16le.length;
      while (_pendingBytes > _maxBufferedBytes && _pending.length > 1) {
        _pendingBytes -= _pending.removeFirst().length;
      }
    } catch (_) {}
  }

  @override
  Future<String> finish() async {
    try {
      if (_closed) return _state.full;
      if (_dead) {
        _state.finishing = true;
        await _closeUpdates();
        return _state.full;
      }
      final Timer deadline = Timer(_service.finishTimeout, _finishTerminal);
      try {
        final bool connected = await _connected.timeout(
          _service.finishTimeout,
          onTimeout: () => false,
        );
        if (connected && !_dead) {
          _state.finishing = true;
          final List<Object> frames = _service.finishMessages(_state);
          _send(frames);
          if (!_dead && !_service.isDrained(_state)) await _terminal.future;
        }
      } finally {
        deadline.cancel();
      }
      _state.finishing = true;
      final String text = _state.full;
      await _shutdown();
      return text;
    } catch (_) {
      final String text = _state.full;
      await _shutdown();
      return text;
    }
  }

  @override
  Future<void> cancel() => _shutdown();

  Future<void> _shutdown() async {
    _closed = true;
    _keepAlive?.cancel();
    _pending.clear();
    _pendingBytes = 0;
    _finishTerminal();
    final WebSocket? socket = _socket;
    _open = false;
    if (socket != null) await _closeSocket(socket);
    await _closeUpdates();
  }

  Future<void> _closeUpdates() async {
    if (!_updates.isClosed) await _updates.close();
  }
}
