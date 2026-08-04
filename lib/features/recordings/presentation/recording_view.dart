// `ValueListenable` lives in foundation; material re-exports only a subset.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../../projects/domain/project.dart';
import '../../settings/domain/audio_config.dart';
import '../../transcription/domain/transcription_limits.dart';
import 'recordings_controller.dart';

/// The capture screen, shown in place of the Queue while the mic is live.
///
/// It exists because a recording in progress is the one moment where the user
/// needs to know exactly what the app is doing with their audio: the format it
/// is being written in, how far the pipeline has got, and — the line at the
/// bottom — that stopping saves the file no matter what happens afterwards.
/// The single full-width `SAVE` is deliberate: there is no discard button,
/// because there is no path in this app that throws a capture away.
class RecordingView extends StatelessWidget {
  const RecordingView({
    super.key,
    required this.controller,
    this.projects = const <Project>[],
  });

  final RecordingsController controller;

  /// Offered as a row of chips so the capture can be re-filed while it runs.
  /// Empty by default — and then the picker is not drawn at all, so an install
  /// with no projects keeps the screen it had.
  final List<Project> projects;

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
            if (projects.isNotEmpty) ...<Widget>[
              _ProjectPicker(controller: controller, projects: projects),
              const SizedBox(height: 14),
            ],
            Text(
              'the source file is never deleted — a processing failure '
              'keeps the audio',
              textAlign: TextAlign.center,
              style: ConsoleText.micro,
            ),
            const SizedBox(height: 14),
            _SaveButton(
              onTap: controller.stopRecording,
              busy: controller.isBusy,
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
            if (controller.recordingLimit != null) ...<Widget>[
              const SizedBox(height: 16),
              _LimitReadout(
                limit: controller.recordingLimit!,
                elapsed: elapsed,
              ),
            ],
          ],
        );
      },
    );
  }
}

/// The remaining time before the capture saves itself, and the reason there is
/// a ceiling at all.
///
/// Shown only where one applies — that is, where the audio cannot be split
/// before it is sent, so the whole file has to survive a single request. On a
/// platform that splits, this is absent rather than reading "unlimited": a line
/// that never changes is a line people stop seeing.
///
/// The point of drawing it is that the automatic save must never be a surprise.
/// The failure it replaces was worse than an interrupted recording — it was a
/// twenty-minute dictation coming back as nine minutes of text, with nothing
/// anywhere saying so.
class _LimitReadout extends StatelessWidget {
  const _LimitReadout({required this.limit, required this.elapsed});

  final TranscriptionCeiling limit;
  final Duration elapsed;

  /// When the pill turns amber. A minute is enough to finish the sentence and
  /// stop deliberately, which is the only reason to show a countdown at all.
  static const Duration _warnAt = Duration(minutes: 1);

  @override
  Widget build(BuildContext context) {
    final Duration left = limit.limit - elapsed;
    final Duration remaining = left.isNegative ? Duration.zero : left;
    final bool near = remaining <= _warnAt;
    final Color color = near ? Console.amber : Console.mutedSoft;

    return Column(
      children: <Widget>[
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: near ? .12 : .06),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: color.withValues(alpha: near ? .45 : .25)),
          ),
          child: Text(
            '${_format(remaining)} LEFT · MAX ${_format(limit.limit)}',
            style: ConsoleText.pill.copyWith(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'saves automatically at the limit — ${limit.reason}',
          textAlign: TextAlign.center,
          style: ConsoleText.micro,
        ),
      ],
    );
  }

  /// `08:00`, `52:00`, `1:44:00`.
  ///
  /// Not [formatDuration]: that one folds hours away with `remainder(60)`,
  /// which is right for a running capture clock and wrong for a ceiling — a low
  /// bitrate puts the 25 MB limit past an hour, and `1:44:00` would have been
  /// drawn as `44:00`.
  static String _format(Duration duration) {
    final String minutes = duration.inMinutes
        .remainder(60)
        .toString()
        .padLeft(2, '0');
    final String seconds = duration.inSeconds
        .remainder(60)
        .toString()
        .padLeft(2, '0');
    if (duration.inHours > 0) return '${duration.inHours}:$minutes:$seconds';
    return '$minutes:$seconds';
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

/// Which project this capture lands in, changeable while the mic is live.
///
/// It sits on the capture screen rather than in front of it because a hotkey
/// recording starts with no UI at all — the window is raised *after* the mic
/// is already running, so any pre-capture picker would be unreachable exactly
/// when capture is fastest. Filing mid-recording also matches how the app is
/// used: you start talking first and work out where it belongs while talking.
///
/// `NONE` is a real option, not an absence: a capture with no project is the
/// normal case, and it has to be reachable after picking one by mistake.
class _ProjectPicker extends StatelessWidget {
  const _ProjectPicker({required this.controller, required this.projects});

  final RecordingsController controller;
  final List<Project> projects;

  @override
  Widget build(BuildContext context) {
    final String? selected = controller.recordingProjectId;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'FILE UNDER',
          style: ConsoleText.micro.copyWith(
            color: Console.muted,
            fontWeight: FontWeight.w800,
            letterSpacing: .6,
          ),
        ),
        const SizedBox(height: 7),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            ConsoleChip(
              label: 'NONE',
              selected: selected == null,
              onSelected: () => controller.setRecordingProject(null),
            ),
            for (final Project project in projects)
              ConsoleChip(
                label: project.name,
                selected: project.id == selected,
                onSelected: () => controller.setRecordingProject(project.id),
              ),
          ],
        ),
      ],
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
