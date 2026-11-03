import 'dart:math' as math;

import 'package:augustyniak_orb/augustyniak_orb.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../domain/capture_type.dart';
import '../domain/recording.dart';
import 'card_parts.dart';

/// The large "something is happening" scene a capture shows while it has
/// nothing to read yet: no transcript (queued, transcribing, OCR) or no rewrite
/// (the enrichment model is working on a capture that has no summary).
///
/// It replaces the small [ProcessingStrip] there, because a one-line strip is
/// easy to miss at the exact moment the user has just stopped talking and
/// wants to know the note was taken. Height is at least [minScreenFraction] of
/// the screen; width is the panel's.
///
/// The animation repeats forever: a test pumping a screen with one of these on
/// it must pump explicit frames, never `pumpAndSettle`. It stands still when
/// the platform asks for reduced motion.
class ProcessingHero extends StatelessWidget {
  ProcessingHero({
    super.key,
    required this.enriching,
    this.type = CaptureType.audioRecording,
    this.processingTicker,
  });

  final bool enriching;
  final CaptureType type;

  /// Running time of the current job, or null when there is none to show.
  final ValueListenable<Duration>? processingTicker;

  /// Share of the screen's height the scene occupies, at minimum.
  static const double minScreenFraction = 0.6;

  /// Whether [recording] has nothing to read yet and should show the hero.
  /// [enriching] is true while the model works on it.
  static bool appliesTo(Recording recording, {required bool enriching}) {
    if (enriching) return (recording.summary ?? '').trim().isEmpty;
    return switch (recording.status) {
      RecordingStatus.pendingTranscription || RecordingStatus.transcribing =>
        (recording.transcript ?? '').trim().isEmpty,
      _ => false,
    };
  }

  static const String queuedLabel = 'QUEUED';

  String get _stage {
    if (enriching) return ProcessingStrip.analyzingLabel;
    return type == CaptureType.image
        ? ProcessingStrip.ocrLabel
        : ProcessingStrip.transcribingLabel;
  }

  String get _caption {
    if (enriching) return 'title · summary · tags';
    return type == CaptureType.image ? 'image → text' : 'speech → text';
  }

  @override
  Widget build(BuildContext context) {
    final double height = math.max(
      360,
      MediaQuery.sizeOf(context).height * ProcessingHero.minScreenFraction,
    );
    final ValueListenable<Duration>? ticker = processingTicker;
    final TextStyle stageStyle = ConsoleText.micro.copyWith(
      color: Console.accent,
      fontSize: 15,
      letterSpacing: 4,
    );
    return ProcessingScene(
      height: height,
      semanticsLabel: '$_stage in progress',
      child: Positioned(
        left: 0,
        right: 0,
        bottom: 28,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(_stage, style: stageStyle),
            const SizedBox(height: 8),
            if (ticker == null)
              Text(
                _caption,
                style: ConsoleText.micro.copyWith(color: Console.muted),
              )
            else
              ValueListenableBuilder<Duration>(
                valueListenable: ticker,
                builder: (BuildContext _, Duration elapsed, Widget? _) => Text(
                  '$_caption · ${formatDuration(elapsed)}',
                  style: ConsoleText.micro.copyWith(color: Console.muted),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The animated visual shared by live recording and post-capture processing.
///
/// A thin frame around [OrbScene] (package `augustyniak_orb`): it builds the
/// preset from the theme in force on every build, so a theme swap repaints.
/// [paused] freezes the current frame so pausing a recording also pauses its
/// motion. The platform reduced-motion setting uses a deliberate still frame
/// at t = [stillFrame].
class ProcessingScene extends StatelessWidget {
  ProcessingScene({
    super.key,
    required this.height,
    required this.semanticsLabel,
    this.paused = false,
    this.child,
  });

  final double height;
  final String semanticsLabel;
  final bool paused;
  final Widget? child;

  /// The reduced-motion frame, as a fraction of the period.
  static const double stillFrame = 0.18;

  @override
  Widget build(BuildContext context) {
    final OrbPreset preset = OrbPreset(
      palette: OrbPalette(
        accent: Console.accent,
        violet: Console.violet,
        pink: Console.pink,
        grid: Console.border,
        backdrop: Console.surfaceDeep,
      ),
    );
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    return Semantics(
      liveRegion: true,
      label: semanticsLabel,
      child: ExcludeSemantics(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Console.surfaceDeep,
              border: Border.all(color: Console.border),
              borderRadius: BorderRadius.circular(18),
            ),
            child: SizedBox(
              height: height,
              width: double.infinity,
              child: OrbScene(
                preset: preset,
                paused: paused || reduceMotion,
                startSeconds: reduceMotion
                    ? stillFrame * preset.tuning.period / preset.tuning.speed
                    : 0,
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
