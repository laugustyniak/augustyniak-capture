import 'dart:io';

import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../domain/capture_category.dart';
import '../domain/capture_type.dart';
import '../domain/recording.dart';

/// The pieces a queue row draws in **both** of its modes.
///
/// They live here rather than in `recording_card.dart` because the inline
/// editor replaces the card's body but keeps its frame: the same leading tile,
/// the same meta line, the same durability footer. Two copies would drift, and
/// importing them out of the card would make the card and the editor import
/// each other.

/// The frame every queue row sits in, read-only or in edit mode.
///
/// The border is the one place state colours the whole item — a failure, a
/// reviewed item and an item being edited all have to be findable while
/// scrolling — so it is the shell's only parameter.
class RecordingCardShell extends StatelessWidget {
  const RecordingCardShell({
    super.key,
    required this.child,
    required this.borderColor,
  });

  final Widget child;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: Console.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
        child: child,
      ),
    );
  }
}

/// The row's leading badge: a video's own poster frame when one was extracted,
/// the capture-type icon otherwise.
///
/// [onOpen] is non-null only for a type the app can hand to the system, which
/// makes the poster a second tap target for the same action the play button
/// runs. The tap target stops here on purpose — the card body stays
/// non-tappable, because "tap anywhere" would make the edit and review controls
/// inside it ambiguous.
class RecordingLeadingTile extends StatelessWidget {
  const RecordingLeadingTile({
    super.key,
    required this.recording,
    required this.failed,
    this.onOpen,
    this.semanticLabel,
    this.size = 30,
  });

  final Recording recording;
  final bool failed;
  final VoidCallback? onOpen;

  /// Announced when [onOpen] is set; shared with the button that runs the same
  /// action so a screen reader hears one action, not two.
  final String? semanticLabel;

  /// One value for both the icon and the poster form, so a row's shape never
  /// depends on whether a frame was extracted. The design shrank this from 38
  /// to a 26–30 px badge: at grid density the tile is an identifier, not an
  /// illustration, and the reclaimed height is what lets a card show two lines
  /// of transcript in the same box.
  final double size;

  @override
  Widget build(BuildContext context) {
    final Color color = failed ? Console.red : Console.cyan;
    final Color background = failed
        ? Console.red.withValues(alpha: .12)
        : Console.iconTile;
    final String? poster = recording.thumbPath;

    final Widget tile = poster == null
        ? ConsoleIconTile(
            animate: true,
            icon: typeIconFor(recording.type),
            color: color,
            background: background,
            size: size,
          )
        // A poster path is only ever a *claim* that a frame was extracted; the
        // file may since have been cleaned up, so the tile falls back to the
        // icon above rather than trusting it.
        : ConsolePosterTile(
            poster: File(poster),
            fallbackIcon: typeIconFor(recording.type),
            color: color,
            background: background,
            size: size,
          );

    if (onOpen == null) return tile;
    return Semantics(
      button: true,
      label: semanticLabel,
      child: InkResponse(onTap: onOpen, radius: 25, child: tile),
    );
  }
}

/// `✓ file verified · 6.8 MB · persisted` — the durability guarantee, stated on
/// every row in every mode. The size segment disappears on legacy rows, which
/// never recorded one, rather than printing a made-up `0 B`.
class VerificationLine extends StatelessWidget {
  const VerificationLine({super.key, required this.recording});

  final Recording recording;

  @override
  Widget build(BuildContext context) {
    final String? size = formatBytes(recording.sizeBytes);
    final String text = <String>[
      'file verified',
      ?size,
      'persisted',
    ].join(' · ');

    return Row(
      children: <Widget>[
        const Icon(Icons.check_rounded, size: 12, color: Console.green),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ConsoleText.micro,
          ),
        ),
      ],
    );
  }
}

/// `10:24 · m4a · 2026-07-27 12:00` — duration only when the type has one, so
/// an image or a note never claims `00:00`.
String metaLineFor(Recording recording, String filename) {
  final String extension = filename.contains('.')
      ? filename.split('.').last.toLowerCase()
      : recording.type.name;
  return <String>[
    if (recording.type.hasDuration && recording.durationMs > 0)
      formatDuration(Duration(milliseconds: recording.durationMs)),
    extension,
    formatDateTime(recording.createdAt),
  ].join(' · ');
}

IconData typeIconFor(CaptureType type) => switch (type) {
  CaptureType.audioRecording => Icons.mic_none_rounded,
  CaptureType.audioUpload => Icons.audio_file_outlined,
  CaptureType.image => Icons.image_outlined,
  CaptureType.text => Icons.description_outlined,
  CaptureType.video => Icons.movie_outlined,
};

/// The colour a category badge carries, from the design's badge map.
///
/// It lives here rather than on [CaptureCategory] for the same reason
/// `typeIconFor` does: the enum is domain, and a domain that imports
/// `material.dart` for a `Color` stops being testable without a binding. The
/// exhaustive `switch` is what makes adding a category break the build here
/// instead of silently rendering it in the fallback colour.
///
/// Categories are **routing destinations**, so the colours group by how the
/// item leaves the app rather than by mood: cyan/violet for the two that feed a
/// machine, amber/green for the two that feed a person, pink for a meeting, and
/// a neutral grey for the two that say "unrouted".
Color categoryColorFor(CaptureCategory category) => switch (category) {
  CaptureCategory.researchLead => Console.cyan,
  CaptureCategory.agentTask => Console.violet,
  CaptureCategory.idea => Console.amber,
  CaptureCategory.task => Console.green,
  CaptureCategory.meetingNote => Console.pink,
  CaptureCategory.note => Console.mutedSoft,
  CaptureCategory.capture => Console.muted,
};
