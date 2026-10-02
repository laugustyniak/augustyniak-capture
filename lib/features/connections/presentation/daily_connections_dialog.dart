import 'package:flutter/material.dart';

import '../../recordings/domain/recording.dart';
import '../domain/daily_connections.dart';

class DailyConnectionsDialog extends StatefulWidget {
  const DailyConnectionsDialog({
    super.key,
    required this.service,
    required this.captures,
    required this.onOpenCapture,
    this.projectNames = const <String, String>{},
  });

  final DailyConnectionsService service;
  final List<Recording> Function() captures;
  final Map<String, String> projectNames;
  final ValueChanged<Recording> onOpenCapture;

  @override
  State<DailyConnectionsDialog> createState() => _DailyConnectionsDialogState();
}

class _DailyConnectionsDialogState extends State<DailyConnectionsDialog> {
  late DateTime _day = DateTime.now();
  DailyConnectionsReport? _report;
  bool _running = false;
  String? _error;

  Future<void> _chooseDay() async {
    final DateTime? selected = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (selected == null || !mounted) return;
    setState(() {
      _day = selected;
      _report = null;
      _error = null;
    });
  }

  Future<void> _run() async {
    if (_running) return;
    final List<Recording> captures = widget.captures();
    setState(() {
      _running = true;
      _error = null;
      _report = null;
    });
    try {
      final DailyConnectionsReport report = await widget.service.review(
        _day,
        captures,
        projectNames: widget.projectNames,
      );
      if (mounted) setState(() => _report = report);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<Recording> captures = widget.captures();
    final List<Recording> eligible = capturesOnDay(captures, _day);
    final Map<String, Recording> byId = <String, Recording>{
      for (final Recording capture in eligible) capture.id: capture,
    };
    final String date = MaterialLocalizations.of(
      context,
    ).formatMediumDate(_day);
    return AlertDialog(
      title: const Text('Daily connections'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Text(
                'Find related captures, different perspectives, and ideas for improving an app. Titles, summaries and text excerpts go to your active enrichment model, which may charge for the review. Your captures stay unchanged.',
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _running ? null : _chooseDay,
                icon: const Icon(Icons.calendar_today_outlined),
                label: Text(date),
              ),
              Text(
                '${eligible.length} text-ready ${eligible.length == 1 ? 'capture' : 'captures'} on this day',
              ),
              if (_running) ...<Widget>[
                const SizedBox(height: 16),
                const LinearProgressIndicator(),
                const SizedBox(height: 8),
                const Text('Reviewing captures…'),
              ],
              if (_error case final String error) ...<Widget>[
                const SizedBox(height: 16),
                Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              if (_report case final DailyConnectionsReport report) ...<Widget>[
                const SizedBox(height: 16),
                if (report.groups.isEmpty)
                  const Text('No strong connections found for this day.'),
                for (final ConnectionGroup group in report.groups) ...<Widget>[
                  const Divider(height: 24),
                  Text(
                    group.title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(_kindLabel(group.kind)),
                  const SizedBox(height: 8),
                  Text(group.explanation),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: <Widget>[
                      for (final String id in group.captureIds)
                        if (byId[id] case final Recording capture)
                          ActionChip(
                            label: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 240),
                              child: Text(
                                capture.title?.trim().isNotEmpty == true
                                    ? capture.title!
                                    : 'Capture ${id.length <= 8 ? id : id.substring(0, 8)}',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            onPressed: () {
                              Navigator.of(context).pop();
                              widget.onOpenCapture(capture);
                            },
                          ),
                    ],
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('CLOSE'),
        ),
        FilledButton(
          onPressed: _running || eligible.isEmpty ? null : _run,
          child: const Text('REVIEW DAY'),
        ),
      ],
    );
  }

  String _kindLabel(ConnectionKind kind) => switch (kind) {
    ConnectionKind.sameTopic => 'Same topic',
    ConnectionKind.complementary => 'Complementary ideas',
    ConnectionKind.differentAngle => 'Different perspectives',
    ConnectionKind.appImprovement => 'App improvement',
  };
}
