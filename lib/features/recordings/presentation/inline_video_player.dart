import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../domain/recording.dart';
import 'recording_card.dart';

/// Manages playback state, position, duration, volume, and error state
/// for in-app inline video playback.
class VideoPlaybackController extends ChangeNotifier {
  VideoPlaybackController({
    required this.videoFile,
    Duration? duration,
    AudioPlayer? player,
    bool autoInitialize = true,
  }) : _duration = duration ?? Duration.zero,
       _player = player {
    if (autoInitialize) {
      unawaited(initialize());
    }
  }

  final File videoFile;
  final AudioPlayer? _player;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _isPlaying = false;
  bool _isBuffering = false;
  bool _isMuted = false;
  double _volume = 1.0;
  String? _error;

  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<void>? _completeSub;
  Timer? _ticker;
  bool _disposed = false;

  Duration get position => _position;
  Duration get duration => _duration;
  bool get isPlaying => _isPlaying;
  bool get isBuffering => _isBuffering;
  bool get isMuted => _isMuted;
  double get volume => _volume;
  String? get error => _error;
  bool get hasError => _error != null;
  bool get isDisposed => _disposed;

  void setBuffering(bool buffering) {
    if (_disposed || _isBuffering == buffering) return;
    _isBuffering = buffering;
    notifyListeners();
  }

  /// Initializes subscriptions and validates the video file.
  Future<void> initialize({Duration? initialDuration}) async {
    if (_disposed) return;
    if (initialDuration != null && initialDuration > Duration.zero) {
      _duration = initialDuration;
    }

    if (!videoFile.existsSync()) {
      _error = 'Video file is missing: ${videoFile.path}';
      _isPlaying = false;
      notifyListeners();
      return;
    }

    _error = null;

    if (_player != null) {
      _positionSub = _player.onPositionChanged.listen((Duration p) {
        if (_disposed) return;
        _position = p;
        notifyListeners();
      });

      _durationSub = _player.onDurationChanged.listen((Duration d) {
        if (_disposed) return;
        if (d > Duration.zero) {
          _duration = d;
          notifyListeners();
        }
      });

      _stateSub = _player.onPlayerStateChanged.listen((PlayerState state) {
        if (_disposed) return;
        final bool playing = state == PlayerState.playing;
        if (_isPlaying != playing) {
          _isPlaying = playing;
          notifyListeners();
        }
      });

      _completeSub = _player.onPlayerComplete.listen((_) {
        if (_disposed) return;
        _isPlaying = false;
        _position = _duration;
        _stopTicker();
        notifyListeners();
      });
    }

    notifyListeners();
  }

  /// Starts playback.
  Future<void> play() async {
    if (_disposed) return;
    if (!videoFile.existsSync()) {
      _error = 'Video file is missing: ${videoFile.path}';
      _isPlaying = false;
      notifyListeners();
      return;
    }

    _error = null;

    // If at end, loop back to start.
    if (_duration > Duration.zero && _position >= _duration) {
      _position = Duration.zero;
    }

    _isPlaying = true;
    notifyListeners();

    if (_player != null) {
      try {
        await _player.play(DeviceFileSource(videoFile.path));
        if (_position > Duration.zero) {
          await _player.seek(_position);
        }
      } catch (e) {
        if (_disposed) return;
        _error = 'Playback failed: $e';
        _isPlaying = false;
        notifyListeners();
        return;
      }
    }

    _startTicker();
  }

  /// Pauses playback.
  Future<void> pause() async {
    if (_disposed) return;
    _isPlaying = false;
    _stopTicker();
    notifyListeners();

    if (_player != null) {
      try {
        await _player.pause();
      } catch (_) {}
    }
  }

  /// Toggles between play and pause.
  Future<void> togglePlay() async {
    if (_isPlaying) {
      await pause();
    } else {
      await play();
    }
  }

  /// Seeks to [targetPosition].
  Future<void> seek(Duration targetPosition) async {
    if (_disposed) return;
    final Duration clamped = Duration(
      milliseconds: targetPosition.inMilliseconds.clamp(
        0,
        _duration > Duration.zero
            ? _duration.inMilliseconds
            : math.max(targetPosition.inMilliseconds, 1),
      ),
    );

    _position = clamped;
    notifyListeners();

    if (_player != null) {
      try {
        await _player.seek(clamped);
      } catch (_) {}
    }
  }

  /// Sets audio volume between 0.0 and 1.0.
  Future<void> setVolume(double vol) async {
    if (_disposed) return;
    _volume = vol.clamp(0.0, 1.0);
    _isMuted = _volume == 0.0;
    notifyListeners();

    if (_player != null) {
      try {
        await _player.setVolume(_volume);
      } catch (_) {}
    }
  }

  /// Toggles mute state.
  Future<void> toggleMute() async {
    if (_isMuted) {
      _isMuted = false;
      await setVolume(_volume == 0.0 ? 1.0 : _volume);
    } else {
      _isMuted = true;
      if (_player != null) {
        try {
          await _player.setVolume(0.0);
        } catch (_) {}
      }
      notifyListeners();
    }
  }

  /// Clears error and attempts re-initialization.
  Future<void> retry() async {
    _error = null;
    notifyListeners();
    await initialize();
  }

  void _startTicker() {
    _stopTicker();
    _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (_disposed || !_isPlaying) {
        _stopTicker();
        return;
      }
      if (_player == null) {
        // Simulated playback ticker for environments without native player
        final int nextMs = _position.inMilliseconds + 200;
        if (_duration > Duration.zero && nextMs >= _duration.inMilliseconds) {
          _position = _duration;
          _isPlaying = false;
          _stopTicker();
        } else {
          _position = Duration(milliseconds: nextMs);
        }
        notifyListeners();
      }
    });
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _stopTicker();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _stateSub?.cancel();
    _completeSub?.cancel();
    super.dispose();
  }
}

/// In-app inline video player widget with poster preview, fallback handling,
/// play/pause controls, seek bar, time display, and error recovery.
class InlineVideoPlayer extends StatefulWidget {
  InlineVideoPlayer({
    super.key,
    required this.videoFile,
    this.posterFile,
    this.duration,
    this.title,
    this.controller,
    this.onOpenExternal,
    this.compact = false,
  });

  /// Convenience constructor to instantiate from a [Recording].
  InlineVideoPlayer.forRecording({
    Key? key,
    required Recording recording,
    VideoPlaybackController? controller,
    VoidCallback? onOpenExternal,
    bool compact = false,
  }) : this(
         key: key,
         videoFile: File(recording.filePath),
         posterFile: recording.thumbPath != null
             ? File(recording.thumbPath!)
             : null,
         duration: Duration(milliseconds: recording.totalDurationMs),
         title: recording.title,
         controller: controller,
         onOpenExternal: onOpenExternal,
         compact: compact,
       );

  final File videoFile;
  final File? posterFile;
  final Duration? duration;
  final String? title;
  final VideoPlaybackController? controller;
  final VoidCallback? onOpenExternal;
  final bool compact;

  @override
  State<InlineVideoPlayer> createState() => _InlineVideoPlayerState();
}

class _InlineVideoPlayerState extends State<InlineVideoPlayer> {
  VideoPlaybackController? _internalController;
  VideoPlaybackController get _controller =>
      widget.controller ?? _internalController!;

  @override
  void initState() {
    super.initState();
    if (widget.controller == null) {
      _internalController = VideoPlaybackController(
        videoFile: widget.videoFile,
        duration: widget.duration,
      );
    }
    _controller.addListener(_onControllerUpdate);
  }

  @override
  void didUpdateWidget(InlineVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller) {
      oldWidget.controller?.removeListener(_onControllerUpdate);
      _internalController?.dispose();
      _internalController = null;

      if (widget.controller == null) {
        _internalController = VideoPlaybackController(
          videoFile: widget.videoFile,
          duration: widget.duration,
        );
      }
      _controller.addListener(_onControllerUpdate);
    } else if (widget.videoFile.path != oldWidget.videoFile.path &&
        widget.controller == null) {
      _controller.removeListener(_onControllerUpdate);
      _internalController?.dispose();
      _internalController = VideoPlaybackController(
        videoFile: widget.videoFile,
        duration: widget.duration,
      );
      _controller.addListener(_onControllerUpdate);
    }
  }

  void _onControllerUpdate() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerUpdate);
    _internalController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final VideoPlaybackController controller = _controller;
    final bool hasError = controller.hasError;
    final bool isPlaying = controller.isPlaying;
    final Duration position = controller.position;
    final Duration duration = controller.duration > Duration.zero
        ? controller.duration
        : (widget.duration ?? Duration.zero);
    final bool isAtEnd =
        duration > Duration.zero && position >= duration && !isPlaying;

    final double maxSeconds = math.max(
      1.0,
      duration.inMilliseconds.toDouble() / 1000.0,
    );
    final double currentSeconds = (position.inMilliseconds.toDouble() / 1000.0)
        .clamp(0.0, maxSeconds);

    return Container(
      decoration: BoxDecoration(
        color: Console.surfaceRaised,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: hasError
              ? Console.red.withValues(alpha: .35)
              : Console.border,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // Screen / Poster / Error area
          AspectRatio(
            aspectRatio: widget.compact ? 16 / 10 : 16 / 9,
            child: Container(
              color: Console.surfaceDeep,
              child: hasError
                  ? _buildErrorView(controller)
                  : _buildVideoSurface(controller, isPlaying, isAtEnd),
            ),
          ),
          // Playback Controls Bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            color: Console.surface,
            child: Row(
              children: <Widget>[
                ConsoleIconButton(
                  icon: isPlaying
                      ? Icons.pause_rounded
                      : isAtEnd
                      ? Icons.replay_rounded
                      : Icons.play_arrow_rounded,
                  onTap: () {
                    if (!hasError) controller.togglePlay();
                  },
                  semanticLabel: isPlaying
                      ? 'Pause video'
                      : isAtEnd
                      ? 'Replay video'
                      : 'Play video',
                  active: isPlaying,
                  size: 30,
                  iconSize: 18,
                ),
                const SizedBox(width: 8),
                Text(
                  '${formatDuration(position)} / ${formatDuration(duration)}',
                  style: ConsoleText.micro.copyWith(
                    color: Console.textSoft,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: SliderTheme(
                    data: SliderThemeData(
                      trackHeight: 3,
                      activeTrackColor: Console.accent,
                      inactiveTrackColor: Console.track,
                      thumbColor: Console.accent,
                      overlayColor: Console.accent.withValues(alpha: .15),
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 6,
                        elevation: 0,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 12,
                      ),
                    ),
                    child: Slider(
                      value: currentSeconds,
                      max: maxSeconds,
                      onChanged: hasError
                          ? null
                          : (double val) => controller.seek(
                              Duration(milliseconds: (val * 1000).round()),
                            ),
                      semanticFormatterCallback: (double val) =>
                          '${formatDuration(Duration(seconds: val.round()))} of ${formatDuration(duration)}',
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                ConsoleIconButton(
                  icon: controller.isMuted
                      ? Icons.volume_off_rounded
                      : Icons.volume_up_rounded,
                  onTap: () => controller.toggleMute(),
                  semanticLabel: controller.isMuted
                      ? 'Unmute video'
                      : 'Mute video',
                  size: 28,
                  iconSize: 16,
                ),
                if (widget.onOpenExternal != null) ...<Widget>[
                  const SizedBox(width: 4),
                  ConsoleIconButton(
                    icon: Icons.open_in_new_rounded,
                    onTap: widget.onOpenExternal!,
                    semanticLabel: RecordingCard.openVideoLabel,
                    size: 28,
                    iconSize: 15,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoSurface(
    VideoPlaybackController controller,
    bool isPlaying,
    bool isAtEnd,
  ) {
    final bool hasPoster =
        widget.posterFile != null && widget.posterFile!.existsSync();

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        // Poster / Placeholder background
        if (hasPoster)
          Image.file(
            widget.posterFile!,
            fit: BoxFit.cover,
            errorBuilder:
                (BuildContext context, Object error, StackTrace? stackTrace) =>
                    _buildFallbackPlaceholder(),
          )
        else
          _buildFallbackPlaceholder(),

        // Tap area to toggle playback
        Semantics(
          button: true,
          label: isPlaying ? 'Pause video screen' : 'Play video screen',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => controller.togglePlay(),
            child: Container(
              color: isPlaying
                  ? Colors.transparent
                  : Console.surfaceDeep.withValues(alpha: .45),
              alignment: Alignment.center,
              child: isPlaying
                  ? const SizedBox.shrink()
                  : Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Console.surface.withValues(alpha: .85),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Console.accent.withValues(alpha: .4),
                        ),
                      ),
                      child: Icon(
                        isAtEnd
                            ? Icons.replay_rounded
                            : Icons.play_arrow_rounded,
                        size: 28,
                        color: Console.accent,
                      ),
                    ),
            ),
          ),
        ),

        // Buffering indicator
        if (controller.isBuffering)
          Center(
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: Console.accent,
            ),
          ),
      ],
    );
  }

  Widget _buildFallbackPlaceholder() {
    return Container(
      color: Console.surfaceDeep,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(
            Icons.movie_outlined,
            size: 36,
            color: Console.muted,
          ),
          if (widget.title != null && widget.title!.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              widget.title!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ConsoleText.micro.copyWith(color: Console.textSoft),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildErrorView(VideoPlaybackController controller) {
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(
            Icons.error_outline_rounded,
            size: 28,
            color: Console.red,
          ),
          const SizedBox(height: 8),
          Text(
            controller.error ?? 'Playback error',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: ConsoleText.micro.copyWith(color: Console.redSoft),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              ConsoleIconButton(
                icon: Icons.refresh_rounded,
                onTap: () => controller.retry(),
                semanticLabel: 'Retry video playback',
                size: 30,
                iconSize: 16,
              ),
              if (widget.onOpenExternal != null) ...<Widget>[
                const SizedBox(width: 8),
                ConsoleIconButton(
                  icon: Icons.open_in_new_rounded,
                  onTap: widget.onOpenExternal!,
                  semanticLabel: RecordingCard.openVideoLabel,
                  size: 30,
                  iconSize: 16,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
