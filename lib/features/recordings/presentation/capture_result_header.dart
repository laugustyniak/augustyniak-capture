import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/ui_kit.dart';
import '../domain/capture_type.dart';
import '../domain/recording.dart';
import '../domain/suggested_route.dart';
import 'recording_editor.dart';
import 'recordings_controller.dart';

/// What the user sees first after STOP: the audio is safe, where the pipeline
/// is, and the one or two things worth doing next.
///
/// Pure view composition. It reads the pipeline from the row and the
/// controller, persists nothing and owns no capture logic: the suggested route
/// goes through [onConfirmSuggestedRoute] (the queue's own handler, the same
/// one the card's chip calls), `+ Fragment` through the panel's append
/// callbacks, Copy through the clipboard. Not `const`: it paints palette
/// colours.
class CaptureResultHeader extends StatelessWidget {
  CaptureResultHeader({
    super.key,
    required this.controller,
    required this.recording,
    this.onConfirmSuggestedRoute,
    this.onAppendRecording,
    this.onAppendNote,
    this.onAppendUpload,
  });

  final RecordingsController controller;
  final Recording recording;

  /// Executes the suggested route; null hides the primary action.
  final Future<void> Function()? onConfirmSuggestedRoute;
  final VoidCallback? onAppendRecording;
  final VoidCallback? onAppendNote;
  final ValueChanged<CaptureType>? onAppendUpload;

  /// A capture the user has finished has nothing left to propose.
  static bool appliesTo(Recording recording) => !recording.isProcessedByUser;

  static const String queuedLabel = 'QUEUED';
  static const String doneLabel = 'DONE';
  static const String failedLabel = 'FAILED';
  static const String enrichingLabel = 'ENRICHING…';
  static const String enrichedLabel = 'ENRICHED';

  static const Key routeButtonKey = Key('result-header-route');
  static const Key copyButtonKey = Key('result-header-copy');
  static const Key boundaryKey = Key('result-header');

  /// `SAVED · 6.8 MB` across every segment, like the card footer; the size is
  /// dropped for a row that never recorded it. No `✓`: the mono face has no
  /// glyph for it, and the green pill already says the file is verified.
  static String savedLabelFor(Recording recording) {
    final String? size = formatBytes(recording.totalSizeBytes);
    return size == null ? 'SAVED' : 'SAVED · $size';
  }

  static String routeLabelFor(SuggestedRouteAction action) =>
      switch (action.kind) {
        SuggestedRouteKind.command => 'Send to Command',
        SuggestedRouteKind.file => 'Send to inbox',
        SuggestedRouteKind.agent =>
          'Hand off to ${action.agentLabel ?? 'agent'}',
        SuggestedRouteKind.none => '',
      };

  @override
  Widget build(BuildContext context) {
    final bool enriching = controller.isEnriching(recording.id);
    final SuggestedRouteAction? route = onConfirmSuggestedRoute == null
        ? null
        : controller.suggestedRouteAction(recording);
    final bool canAppend =
        onAppendRecording != null ||
        onAppendNote != null ||
        onAppendUpload != null;
    final String text = recording.displayText;

    return RepaintBoundary(
      key: boundaryKey,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Console.surface,
          border: Border.all(color: Console.border),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                StatusPill(
                  label: savedLabelFor(recording),
                  color: Console.green,
                ),
                _arrow(),
                _statusPill(),
                if (enriching)
                  StatusPill(
                    label: enrichingLabel,
                    color: Console.accent,
                    pulse: true,
                  )
                else if (recording.category != null)
                  StatusPill(label: enrichedLabel, color: Console.violet),
              ],
            ),
            if (route != null || text.isNotEmpty || canAppend) ...<Widget>[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  if (route != null)
                    _RouteButton(
                      key: routeButtonKey,
                      label: routeLabelFor(route),
                      reason: route.reason,
                      onConfirm: onConfirmSuggestedRoute!,
                    ),
                  if (text.isNotEmpty) _CopyButton(text: text),
                  if (canAppend)
                    _HeaderButton(
                      icon: Icons.add_rounded,
                      label: '+ Fragment',
                      onPressed: () => showAppendFragmentMenu(
                        context,
                        onAppendRecording: onAppendRecording,
                        onAppendNote: onAppendNote,
                        onAppendUpload: onAppendUpload,
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _arrow() => Icon(Icons.chevron_right, size: 14, color: Console.muted);

  Widget _statusPill() {
    return switch (recording.status) {
      RecordingStatus.saved || RecordingStatus.pendingTranscription =>
        StatusPill(label: queuedLabel, color: Console.muted, outlined: true),
      RecordingStatus.transcribing => StatusPill(
        label: recording.type == CaptureType.image
            ? 'EXTRACTING'
            : 'TRANSCRIBING',
        color: Console.accent,
        pulse: true,
      ),
      RecordingStatus.completed => StatusPill(
        label: doneLabel,
        color: Console.green,
      ),
      RecordingStatus.failed => StatusPill(
        label: failedLabel,
        color: Console.red,
      ),
    };
  }
}

/// The primary action. It stays disabled until the handler's future completes:
/// `route()` records the route only after the delivery returns, so until then
/// the capture still looks unrouted and a second tap would deliver it again.
class _RouteButton extends StatefulWidget {
  const _RouteButton({
    super.key,
    required this.label,
    required this.reason,
    required this.onConfirm,
  });

  final String label;
  final String? reason;
  final Future<void> Function() onConfirm;

  @override
  State<_RouteButton> createState() => _RouteButtonState();
}

class _RouteButtonState extends State<_RouteButton> {
  bool _routing = false;

  Future<void> _confirm() async {
    setState(() => _routing = true);
    try {
      await widget.onConfirm();
    } finally {
      if (mounted) setState(() => _routing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final Widget button = _HeaderButton(
      icon: Icons.outbound_outlined,
      label: widget.label,
      primary: true,
      onPressed: _routing ? null : _confirm,
    );
    final String? reason = widget.reason;
    return reason == null ? button : Tooltip(message: reason, child: button);
  }
}

class _HeaderButton extends StatelessWidget {
  _HeaderButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.primary = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: primary ? Console.ink : Console.text,
        backgroundColor: primary ? Console.accent : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        minimumSize: const Size(0, 34),
        textStyle: ConsoleText.body.copyWith(
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: primary ? BorderSide.none : BorderSide(color: Console.border),
        ),
      ),
      icon: Icon(icon, size: 16),
      label: Text(label),
    );
  }
}

/// Copy that answers: the app uses no snackbars, so the label says `Copied`.
class _CopyButton extends StatefulWidget {
  _CopyButton({required this.text});

  final String text;

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _copied = false;
  Timer? _reset;

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (!mounted) return;
    setState(() => _copied = true);
    _reset?.cancel();
    _reset = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return _HeaderButton(
      key: CaptureResultHeader.copyButtonKey,
      icon: _copied ? Icons.check_rounded : Icons.copy_rounded,
      label: _copied ? 'Copied' : 'Copy',
      onPressed: _copy,
    );
  }
}
