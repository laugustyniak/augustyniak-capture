// `ValueListenable` lives in foundation; material re-exports only a subset.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../../settings/domain/audio_config.dart';
import 'recordings_controller.dart';

/// The capture screen, shown in place of the Queue while the mic is live.
///
/// It exists because a recording in progress is the one moment where the user
/// needs to know exactly what the app is doing with their audio: the format it
/// is being written in, how far the pipeline has got, and — the line at the
/// bottom — that stopping saves the file no matter what happens afterwards.
///
/// `SAVE` keeps the whole width and the accent colour; `DISCARD` is a narrow
/// outline beside it and asks for confirmation first. The asymmetry is the
/// design: throwing a take away is the only irreversible thing this screen can
/// do, so it must be reachable — a mistimed start otherwise leaves rubbish that
/// can only be cleaned up after it has been transcribed — but it must never be
/// the button a thumb finds by accident while reaching for stop.
class RecordingView extends StatelessWidget {
  const RecordingView({super.key, required this.controller});

  /// Public so the confirmation test asserts on the string that is rendered.
  static const String discardLabel = 'Discard recording without saving';

  final RecordingsController controller;

  /// Confirmed because it is unrecoverable: the partial `.m4a` is deleted and
  /// was never indexed, so unlike every other file in this app there is no
  /// orphan sweep that could bring it back.
  Future<void> _confirmDiscard(BuildContext context) async {
    final bool confirmed = await confirmDestructive(
      context,
      title: 'Discard this recording?',
      message:
          'The audio recorded so far is deleted and nothing is written to '
          'the queue. This cannot be undone.',
      confirmLabel: 'DISCARD',
    );
    if (confirmed) await controller.discardRecording();
  }

  @override
  Widget build(BuildContext context) {
    final AudioConfig audio = controller.audioConfig;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                const Text('AUGUSTYNIAK CAPTURE', style: ConsoleText.eyebrow),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Console.red.withValues(alpha: .1),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: Console.red.withValues(alpha: .35),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const PulseDot(color: Console.red, size: 7),
                      const SizedBox(width: 7),
                      Text(
                        'REC',
                        style: ConsoleText.pill.copyWith(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: Console.red,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  _ElapsedReadout(controller: controller, audio: audio),
                  const SizedBox(height: 26),
                  _LevelMeter(level: controller.levelTicker),
                  const SizedBox(height: 26),
                  const _PipelineChecklist(),
                ],
              ),
            ),
            Text(
              'saving is the only way out that keeps the audio — a processing '
              'failure never deletes it, only DISCARD does',
              textAlign: TextAlign.center,
              style: ConsoleText.micro,
            ),
            const SizedBox(height: 14),
            Row(
              children: <Widget>[
                _DiscardButton(
                  onTap: () => _confirmDiscard(context),
                  busy: controller.isBusy,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _SaveButton(
                    onTap: controller.stopRecording,
                    busy: controller.isBusy,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Running time plus the exact format being written. Subscribes to the ticker
/// on its own so four repaints a second never reach the rest of the screen.
class _ElapsedReadout extends StatelessWidget {
  const _ElapsedReadout({required this.controller, required this.audio});

  final RecordingsController controller;
  final AudioConfig audio;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Duration>(
      valueListenable: controller.elapsedTicker,
      builder: (BuildContext context, Duration elapsed, Widget? child) {
        // Bytes so far, from the configured bitrate — marked `~` because it is
        // the encoder's target, not a measurement of the file on disk.
        final int approximateBytes =
            (audio.bitRate / 8 * elapsed.inMilliseconds / 1000).round();
        final String? size = formatBytes(approximateBytes);

        return Column(
          children: <Widget>[
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: <Widget>[
                Text(
                  formatDuration(elapsed),
                  style: const TextStyle(
                    fontFamily: ConsoleFont.mono,
                    fontSize: 52,
                    height: 1,
                    fontWeight: FontWeight.w700,
                    color: Console.text,
                  ),
                ),
                Text(
                  '.${(elapsed.inMilliseconds ~/ 100) % 10}',
                  style: const TextStyle(
                    fontFamily: ConsoleFont.mono,
                    fontSize: 28,
                    height: 1,
                    fontWeight: FontWeight.w700,
                    color: Console.dim,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              <String>[
                'AAC-LC',
                '${(audio.sampleRate / 1000).toStringAsFixed(audio.sampleRate % 1000 == 0 ? 0 : 1)} kHz',
                audio.isMono ? 'mono' : 'stereo',
                '${audio.bitRate ~/ 1000} kbps',
                if (size != null) '~$size',
              ].join(' · '),
              style: ConsoleText.cardMeta.copyWith(fontWeight: FontWeight.w500),
            ),
          ],
        );
      },
    );
  }
}

/// Scrolling input-level meter. Keeps its own short history of the level
/// notifier so the bars read as a moving signal rather than one jumping value.
class _LevelMeter extends StatefulWidget {
  const _LevelMeter({required this.level});

  final ValueListenable<double> level;

  @override
  State<_LevelMeter> createState() => _LevelMeterState();
}

class _LevelMeterState extends State<_LevelMeter> {
  static const int _barCount = 33;

  /// Fixed length on purpose: [build] indexes every slot, so the meter's shape
  /// must never depend on how many samples have arrived yet. The window is
  /// therefore shifted in place — `removeAt`/`add` both throw on a list built
  /// this way, which is how the meter once shipped dead: a fake recorder
  /// reports no amplitude at all, so nothing but a real microphone reaches the
  /// listener that would have raised it.
  final List<double> _history = List<double>.filled(_barCount, 0);

  @override
  void initState() {
    super.initState();
    widget.level.addListener(_onLevel);
  }

  @override
  void dispose() {
    widget.level.removeListener(_onLevel);
    super.dispose();
  }

  void _onLevel() {
    if (!mounted) return;
    setState(() {
      // Drop the oldest sample and append the newest without resizing: every
      // slot moves one place left, and the freed last slot takes the new value.
      _history.setRange(0, _barCount - 1, _history, 1);
      _history[_barCount - 1] = widget.level.value;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 72,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: List<Widget>.generate(_barCount, (int index) {
          final double level = _history[index];
          // Newest sample on the right; anything still at the resting height
          // is drawn in the dim track colour, like the design's tail.
          final double height = 6 + level * 60;
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2.5),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                height: height,
                decoration: BoxDecoration(
                  color: level <= 0 ? Console.track : Console.cyan,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

/// The four ordered steps of a capture, with the one in progress lit. Stating
/// the order on screen is the point: persist happens before processing, always.
class _PipelineChecklist extends StatelessWidget {
  const _PipelineChecklist();

  static const List<String> _steps = <String>[
    'recording → .m4a',
    'stop · verify file > 0 B',
    'persist recordings.json (atomic)',
    'queue → process',
  ];

  @override
  Widget build(BuildContext context) {
    return ConsoleCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (int index = 0; index < _steps.length; index++)
            Padding(
              padding: EdgeInsets.only(top: index == 0 ? 0 : 10),
              child: Row(
                children: <Widget>[
                  if (index == 0)
                    const PulseDot(color: Console.cyan, size: 7)
                  else
                    Container(
                      width: 7,
                      height: 7,
                      decoration: const BoxDecoration(
                        color: Console.track,
                        shape: BoxShape.circle,
                      ),
                    ),
                  const SizedBox(width: 10),
                  Text(
                    _steps[index],
                    style: index == 0
                        ? ConsoleText.cardMeta.copyWith(
                            fontWeight: FontWeight.w500,
                            color: Console.text,
                          )
                        : ConsoleText.micro.copyWith(fontSize: 11),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The escape hatch, deliberately undersized. Matches [_SaveButton]'s height so
/// the pair reads as one control strip, and carries no fill of its own — the
/// red only appears once the confirmation dialog is on screen.
class _DiscardButton extends StatelessWidget {
  const _DiscardButton({required this.onTap, required this.busy});

  final VoidCallback onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: RecordingView.discardLabel,
      child: InkWell(
        onTap: busy ? null : onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: busy ? Console.border : Console.red.withValues(alpha: .45),
            ),
          ),
          child: Icon(
            Icons.delete_outline_rounded,
            size: 19,
            color: busy ? Console.muted : Console.redSoft,
          ),
        ),
      ),
    );
  }
}

class _SaveButton extends StatelessWidget {
  const _SaveButton({required this.onTap, required this.busy});

  final VoidCallback onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Stop recording and save',
      child: InkWell(
        onTap: busy ? null : onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 18),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: busy ? Console.surfaceRaised : Console.cyan,
            borderRadius: BorderRadius.circular(14),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Console.cyan.withValues(alpha: busy ? 0 : .35),
                blurRadius: 28,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Text(
            busy ? 'SAVING' : 'SAVE',
            style: TextStyle(
              fontFamily: ConsoleFont.display,
              fontSize: 15,
              fontWeight: FontWeight.w700,
              letterSpacing: 2.4,
              color: busy ? Console.muted : Console.ink,
            ),
          ),
        ),
      ),
    );
  }
}
