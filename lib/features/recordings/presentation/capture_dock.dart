import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import 'recordings_controller.dart';

/// The capture controls that float over the bottom of the Queue.
///
/// Two buttons, deliberately unequal: recording is one tap on a 64 px cyan
/// target, everything else is one tap on a smaller neutral one. The gradient
/// underneath is what makes that readable — without it the list scrolls into
/// the buttons and the cyan disc lands on top of a card.
class CaptureDock extends StatelessWidget {
  const CaptureDock({
    super.key,
    required this.controller,
    required this.onOpenCaptureMenu,
  });

  final RecordingsController controller;

  /// Opens the `+` sheet (note, audio/image/video upload).
  final VoidCallback onOpenCaptureMenu;

  @override
  Widget build(BuildContext context) {
    final bool busy = controller.isBusy;

    return Column(
      mainAxisSize: MainAxisSize.min,
      // Stretch, not the default centre: the scrim and the solid footer have
      // no intrinsic width, so centring collapses both to a narrow band and
      // the buttons end up floating over a card instead of over a fade.
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // Taps have to reach the list underneath the fade, or the last card in
        // the queue would be unreachable behind 90 px of gradient.
        IgnorePointer(
          child: Container(
            height: 90,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[
                  Console.background.withValues(alpha: 0),
                  Console.background,
                ],
              ),
            ),
          ),
        ),
        ColoredBox(
          color: Console.background,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                _SecondaryCaptureButton(onTap: busy ? null : onOpenCaptureMenu),
                const SizedBox(height: 10),
                _RecordButton(controller: controller),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// The 44 px neutral disc above the record button — notes and uploads.
class _SecondaryCaptureButton extends StatelessWidget {
  const _SecondaryCaptureButton({required this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'New note or upload',
      child: Tooltip(
        message: 'New note or upload',
        child: InkResponse(
          onTap: onTap,
          radius: 28,
          child: Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Console.surfaceRaised,
              shape: BoxShape.circle,
              border: Border.all(color: Console.borderStrong),
              boxShadow: const <BoxShadow>[
                BoxShadow(
                  color: Console.shadow,
                  blurRadius: 18,
                  offset: Offset(0, 6),
                ),
              ],
            ),
            child: Icon(
              Icons.edit_outlined,
              size: 17,
              color: onTap == null ? Console.dim : Console.mutedSoft,
            ),
          ),
        ),
      ),
    );
  }
}

/// The 64 px cyan record disc. Starting a recording swaps the whole screen for
/// the capture view, so this button only ever has to say "start" — the stop and
/// save affordance lives there, where it cannot be mistaken for anything else.
class _RecordButton extends StatelessWidget {
  const _RecordButton({required this.controller});

  final RecordingsController controller;

  @override
  Widget build(BuildContext context) {
    final bool busy = controller.isBusy;

    return Semantics(
      button: true,
      label: busy ? 'Saving capture' : 'Start recording',
      child: InkResponse(
        onTap: busy ? null : controller.startRecording,
        radius: 40,
        child: Container(
          width: 64,
          height: 64,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: busy ? Console.surfaceRaised : Console.cyan,
            shape: BoxShape.circle,
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Console.cyan.withValues(alpha: busy ? 0 : .35),
                blurRadius: 28,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: busy
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.4,
                    color: Console.cyan,
                  ),
                )
              : const Icon(
                  Icons.mic_none_rounded,
                  size: 26,
                  color: Console.ink,
                ),
        ),
      ),
    );
  }
}
