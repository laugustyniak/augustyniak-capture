import 'dart:math';

import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../domain/recording.dart';

/// What the SCHEDULE dialog decided (#383). [at] null with [clear] true means
/// "drop the schedule"; otherwise the capture waits until [at] and, when
/// [repeatEveryDays] is set, comes back that many days after every DONE.
class ScheduleChoice {
  const ScheduleChoice({this.at, this.repeatEveryDays, this.clear = false});

  const ScheduleChoice.clear() : this(clear: true);

  final DateTime? at;
  final int? repeatEveryDays;
  final bool clear;
}

/// The repeat options the dialog offers, in days. A month is thirty days on
/// purpose: the interval is a plain day count, and calling it a calendar month
/// would promise a date arithmetic the field does not carry.
const Map<String, int?> scheduleRepeatOptions = <String, int?>{
  'No repeat': null,
  'Every day': 1,
  'Every week': 7,
  'Every month': 30,
};

/// The preset dates, computed from [now] at 09:00 local — a capture returning
/// at 03:12 because that is when it was scheduled helps nobody.
///
/// "Next month" is the same day of the following month, clamped to that
/// month's last day: `DateTime` rolls an overflowing day forward, so an
/// unclamped Jan 31 would land on Mar 3.
Map<String, DateTime> schedulePresets(DateTime now) {
  // Day 0 of the month after next is the last day of next month.
  final int lastOfNext = DateTime(now.year, now.month + 2, 0).day;
  return <String, DateTime>{
    'Tomorrow': DateTime(now.year, now.month, now.day + 1, 9),
    'Next week': DateTime(now.year, now.month, now.day + 7, 9),
    'Next month': DateTime(
      now.year,
      now.month + 1,
      min(now.day, lastOfNext),
      9,
    ),
  };
}

/// Asks when [recording] should return to the desk. Null on dismiss.
Future<ScheduleChoice?> showScheduleDialog(
  BuildContext context,
  Recording recording,
) {
  return showDialog<ScheduleChoice>(
    context: context,
    builder: (BuildContext dialogContext) =>
        _ScheduleDialog(recording: recording),
  );
}

class _ScheduleDialog extends StatefulWidget {
  _ScheduleDialog({required this.recording});

  final Recording recording;

  @override
  State<_ScheduleDialog> createState() => _ScheduleDialogState();
}

class _ScheduleDialogState extends State<_ScheduleDialog> {
  late int? _repeat = widget.recording.repeatEveryDays;

  void _pick(DateTime at) => Navigator.of(
    context,
  ).pop(ScheduleChoice(at: at, repeatEveryDays: _repeat));

  Future<void> _pickDate() async {
    final DateTime now = DateTime.now();
    final DateTime? day = await showDatePicker(
      context: context,
      initialDate: DateTime(now.year, now.month, now.day + 1),
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 5),
    );
    if (day == null || !mounted) return;
    _pick(DateTime(day.year, day.month, day.day, 9));
  }

  @override
  Widget build(BuildContext context) {
    final DateTime now = DateTime.now();
    final bool scheduled =
        widget.recording.resurfaceAt != null ||
        widget.recording.repeatEveryDays != null;
    return AlertDialog(
      backgroundColor: Console.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: Console.border),
      ),
      title: Text(
        'Schedule',
        style: ConsoleText.body.copyWith(
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Off the desk until then. A repeating capture comes back after '
              'every DONE.',
              style: ConsoleText.body.copyWith(color: Console.muted),
            ),
            const SizedBox(height: 14),
            Text('REPEAT', style: ConsoleText.chip),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                for (final MapEntry<String, int?> option
                    in scheduleRepeatOptions.entries)
                  ConsoleChip(
                    label: option.key,
                    selected: _repeat == option.value,
                    onSelected: () => setState(() => _repeat = option.value),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Text('RETURNS', style: ConsoleText.chip),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                for (final MapEntry<String, DateTime> preset in schedulePresets(
                  now,
                ).entries)
                  OutlinedButton(
                    onPressed: () => _pick(preset.value),
                    child: Text(preset.key),
                  ),
                OutlinedButton(
                  onPressed: _pickDate,
                  child: const Text('Pick date…'),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: <Widget>[
        if (scheduled)
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(const ScheduleChoice.clear()),
            child: const Text('CLEAR SCHEDULE'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('CANCEL'),
        ),
      ],
    );
  }
}
