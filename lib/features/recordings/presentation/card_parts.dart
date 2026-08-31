import 'dart:io';

import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../domain/capture_category.dart';
import '../domain/capture_type.dart';
import '../domain/recording.dart';
import '../domain/route_record.dart';

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
  });

  final Recording recording;
  final bool failed;
  final VoidCallback? onOpen;

  /// Announced when [onOpen] is set; shared with the button that runs the same
  /// action so a screen reader hears one action, not two.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final Color color = failed ? Console.red : Console.accent;
    final Color background = failed
        ? Console.red.withValues(alpha: .1)
        : Console.iconTile;
    final String? poster = recording.thumbPath;

    final Widget tile = poster == null
        ? ConsoleIconTile(
            animate: true,
            icon: typeIconFor(recording.type),
            color: color,
            background: background,
          )
        // A poster path is only ever a *claim* that a frame was extracted; the
        // file may since have been cleaned up, so the tile falls back to the
        // icon above rather than trusting it.
        : ConsolePosterTile(
            poster: File(poster),
            fallbackIcon: typeIconFor(recording.type),
            color: color,
            background: background,
          );

    if (onOpen == null) return tile;
    return Semantics(
      button: true,
      label: semanticLabel,
      child: InkResponse(onTap: onOpen, radius: 25, child: tile),
    );
  }
}

/// `✓ file verified · 6.8 MB · $0.0021 · persisted` — the durability guarantee,
/// stated on every row in every mode, with what the capture cost folded into
/// the same line. The size segment disappears on legacy rows, which never
/// recorded one, rather than printing a made-up `0 B`; the cost segment does
/// the same for [costUsd] — null means no usage event exists yet, which reads
/// as `cost —` rather than the false claim `$0.0000` would make. That
/// distinction is the whole point of cost tracking, so it is never collapsed.
class VerificationLine extends StatelessWidget {
  // Not `const`: this widget paints `Console.green`, and a const constructor
  // would keep painting the previous palette after a theme swap — a stale
  // frame no widget test can see. See the theme rule in CLAUDE.md.
  VerificationLine({super.key, required this.recording, this.costUsd});

  final Recording recording;

  /// Sum of this capture's usage events. Null means no event has been recorded
  /// for it yet (no API call made, or the feature predates this capture) — a
  /// state distinct from "it cost nothing" and rendered as `cost —` rather
  /// than as a zero.
  final double? costUsd;

  @override
  Widget build(BuildContext context) {
    // Across every segment, not just the first: a capture that gained a
    // fragment holds more bytes than its row-level field describes, and the
    // footer reports what is actually on disk.
    final String? size = formatBytes(recording.totalSizeBytes);
    final String text = <String>[
      'file verified',
      ?size,
      costUsd == null ? 'cost —' : formatUsd(costUsd!),
      'persisted',
    ].join(' · ');

    return Row(
      children: <Widget>[
        Icon(Icons.check_rounded, size: 12, color: Console.green),
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

/// What the row calls itself when enrichment has not named it.
///
/// The slot used to fall straight through to the source filename, which is a
/// uuid — the worst answer available, because a column of them is not merely
/// uninformative but mutually *indistinguishable*: scanning, recognition and
/// sorting-by-eye all stop working at once, and that is the state of every
/// install with no enrichment profile configured. The transcript's opening
/// words are always a better name than the file's, and a timestamp is better
/// than a hash. The filename stays reachable in the meta line, where it is a
/// diagnostic rather than a title.
/// It is deliberately *not* the opening words of the transcript, which is the
/// obvious alternative: the card already renders three lines of that text
/// directly underneath, so a content-derived name would print the same sentence
/// twice on every un-enriched row. `Voice note · 17:09` says what the row is
/// and separates it from its neighbours by the one fact that always differs,
/// while leaving the content to the excerpt that already carries it.
String displayNameFor(Recording recording) {
  final String? title = recording.title?.trim();
  if (title != null && title.isNotEmpty) return title;
  return '${typeLabelFor(recording.type)} · '
      '${formatTimeOfDay(recording.createdAt)}';
}

/// The colour a category is scanned by — the dot on a compact row and the pill
/// on both forms.
///
/// The five the design names get the five hues it picked, and they are the five
/// a user actually sorts by. The other two are deliberately colourless: [note]
/// is the resting kind, and [capture] means *the model looked and could not
/// place it* — giving that a colour of its own would make "unclassified" look
/// like a sixth destination rather than the absence of one.
///
/// Null (enrichment never ran) answers the accent, not a category colour: it is
/// the same "nothing to say here" the card already draws with no pill at all.
Color categoryColorFor(CaptureCategory? category) => switch (category) {
  CaptureCategory.researchLead => Console.accent,
  CaptureCategory.agentTask => Console.violet,
  CaptureCategory.idea => Console.amber,
  CaptureCategory.task => Console.green,
  CaptureCategory.meetingNote => Console.pink,
  CaptureCategory.note => Console.muted,
  CaptureCategory.capture => Console.dimText,
  null => Console.accent,
};

String typeLabelFor(CaptureType type) => switch (type) {
  CaptureType.audioRecording => 'Voice note',
  CaptureType.audioUpload => 'Audio file',
  CaptureType.image => 'Image',
  CaptureType.text => 'Text note',
  CaptureType.video => 'Video',
};

/// `10:24 · m4a · 2026-07-27 12:00` — duration only when the type has one, so
/// an image or a note never claims `00:00`.
String metaLineFor(Recording recording, String filename) {
  final String extension = filename.contains('.')
      ? filename.split('.').last.toLowerCase()
      : recording.type.name;
  return <String>[
    // Summed across segments for the same reason the size is: two recordings
    // appended to one capture are one capture's worth of listening.
    if (recording.type.hasDuration && recording.totalDurationMs > 0)
      formatDuration(Duration(milliseconds: recording.totalDurationMs)),
    extension,
    formatDateTime(recording.createdAt),
  ].join(' · ');
}

/// What a capture is doing right now, drawn while it does it: a moving glyph, a
/// label naming the stage, and a band of light under both.
///
/// It exists for the phone form, where the desktop card's two separate signals
/// — a `LinearProgressIndicator` for transcription and a scan line for the
/// enrichment pass — have no room to live side by side, and where a row is one
/// line tall so a pill alone is easy to scroll past.
///
/// The two stages are drawn by *different* animations rather than one shared
/// one. On a phone they follow each other within seconds on the same row, and
/// the failure to avoid is a user who looks up mid-way and cannot tell which
/// one they are watching — which is the same reason the label is spelled out
/// rather than left to the glyph.
///
/// Both animations repeat forever: a test pumping a screen with one of these on
/// it must pump explicit frames, never `pumpAndSettle`.
class ProcessingStrip extends StatelessWidget {
  ProcessingStrip({super.key, required this.enriching});

  /// True while the model reads the text; false while the audio is being
  /// transcribed. Only these two stages animate — everything else in the
  /// pipeline is either instant or waiting for its turn.
  final bool enriching;

  /// Public so a widget test asserts the string that is actually rendered
  /// rather than a copy of it, the same rule `RecordingCard.analyzingLabel`
  /// follows on the desktop card.
  static const String transcribingLabel = 'TRANSCRIBING';
  static const String analyzingLabel = 'ANALYZING';

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            SizedBox(
              // A fixed slot for the two glyphs: a wave is wider than an icon,
              // and without it the label would shift sideways at the exact
              // moment the stage changes — the one moment the eye is on it.
              width: 22,
              child: Align(
                alignment: Alignment.centerLeft,
                child: enriching
                    ? SparklePulse(color: Console.accent, size: 14)
                    : WaveBars(color: Console.accent, height: 13, barCount: 4),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              enriching ? analyzingLabel : transcribingLabel,
              style: ConsoleText.micro.copyWith(color: Console.accent),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                enriching ? 'title · summary · tags' : 'speech → text',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: ConsoleText.micro.copyWith(color: Console.muted),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ScanLine(height: 3),
      ],
    );
  }
}

/// What the tag row hands to the clipboard: `#idea #calendar #q3`.
///
/// One definition for all three forms that draw tags — the card, the compact
/// row and the focus modal — because the hash prefix is not decoration. It is
/// what makes the pasted line a tag line in Obsidian and in every other notes
/// tool the vault mirror already targets, so a form that dropped it would paste
/// something that merely looks the same as the chips on screen.
String tagsClipboardText(List<String> tags) =>
    tags.map((String tag) => '#$tag').join(' ');

IconData typeIconFor(CaptureType type) => switch (type) {
  CaptureType.audioRecording => Icons.mic_none_rounded,
  CaptureType.audioUpload => Icons.audio_file_outlined,
  CaptureType.image => Icons.image_outlined,
  CaptureType.text => Icons.description_outlined,
  CaptureType.video => Icons.movie_outlined,
};


/// The one line a capture gets about what became of it.
///
/// `checkedAt` is when this app last *asked*, not when anything changed, and
/// the line says so — "nobody has looked lately" and "nothing has happened"
/// are different facts and the whole reason a failed refresh keeps the previous
/// answer instead of clearing it.
String outcomeLineFor(RouteOutcome outcome) {
  final StringBuffer buffer = StringBuffer(_stateLabel(outcome.state));
  if (outcome.issues.isNotEmpty) {
    final String numbers = outcome.issues
        .take(3)
        .map((int issue) => '#$issue')
        .join(' ');
    buffer.write(
      ' · $numbers${outcome.issues.length > 3 ? ' +${outcome.issues.length - 3}' : ''}',
    );
  }
  if (outcome.prUrl != null) buffer.write(' · PR');
  buffer.write(' · checked ${formatClock(outcome.checkedAt)}');
  return buffer.toString();
}

String _stateLabel(CommandState state) => switch (state) {
  CommandState.submitted => 'SUBMITTED',
  CommandState.planned => 'PLANNED',
  CommandState.inProgress => 'IN PROGRESS',
  CommandState.done => 'DONE',
  CommandState.blocked => 'BLOCKED',
  CommandState.needsReview => 'NEEDS REVIEW',
};
