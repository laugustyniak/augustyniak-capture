import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/ui_kit.dart';
import '../data/log_store.dart';
import '../domain/log_event.dart';

/// Read-only processing console. Shows pipeline transitions newest first.
/// Nothing here mutates recordings.
class LogsTab extends StatefulWidget {
  const LogsTab({super.key, required this.store});

  final LogStore store;

  @override
  State<LogsTab> createState() => _LogsTabState();
}

class _LogsTabState extends State<LogsTab> {
  LogLevel? levelFilter;

  @override
  Widget build(BuildContext context) {
    final LogStore store = widget.store;
    final List<LogEvent> visible = store.eventsAtLevel(levelFilter);

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 40),
        children: <Widget>[
          ConsoleHeader(
            title: 'Logs',
            trailing:
                '${store.events.length} '
                '${store.events.length == 1 ? 'event' : 'events'}',
          ),
          const SizedBox(height: 18),
          _LevelFilterRow(
            selected: levelFilter,
            counts: <LogLevel?, int>{
              null: store.events.length,
              LogLevel.info: store.countAtLevel(LogLevel.info),
              LogLevel.warn: store.countAtLevel(LogLevel.warn),
              LogLevel.error: store.countAtLevel(LogLevel.error),
            },
            onSelected: (LogLevel? value) =>
                setState(() => levelFilter = value),
          ),
          const SizedBox(height: 18),
          SectionHeader(
            title: 'EVENT STREAM',
            trailing: '${visible.length} / ${store.capacity} MAX',
          ),
          const SizedBox(height: 12),
          if (visible.isEmpty)
            EmptyPanel(
              icon: Icons.terminal_outlined,
              title: 'No events.',
              blurb:
                  'Record a note — every pipeline step (save, queue, '
                  'transcription, errors) shows up here.',
            )
          else
            ...visible.map(
              (LogEvent event) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _LogRow(event: event),
              ),
            ),
          if (store.events.isNotEmpty) ...<Widget>[
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () => _confirmClear(context),
              style: OutlinedButton.styleFrom(
                foregroundColor: Console.redSoft,
                side: BorderSide(color: Console.border),
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              icon: const Icon(Icons.delete_sweep_outlined, size: 18),
              label: const Text(
                'CLEAR LOGS',
                style: TextStyle(fontWeight: FontWeight.w900, fontSize: 12),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _confirmClear(BuildContext context) async {
    final bool confirmed = await confirmDestructive(
      context,
      title: 'Clear logs?',
      message:
          'The event history will be deleted. Recordings and transcripts '
          'stay untouched.',
      confirmLabel: 'CLEAR',
    );
    if (confirmed) {
      await widget.store.clear();
    }
  }
}

class _LevelFilterRow extends StatelessWidget {
  const _LevelFilterRow({
    required this.selected,
    required this.counts,
    required this.onSelected,
  });

  final LogLevel? selected;
  final Map<LogLevel?, int> counts;
  final ValueChanged<LogLevel?> onSelected;

  @override
  Widget build(BuildContext context) {
    const List<LogLevel?> options = <LogLevel?>[
      null,
      LogLevel.info,
      LogLevel.warn,
      LogLevel.error,
    ];

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: options.map((LogLevel? level) {
          final bool active = level == selected;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ConsoleChip(
              label: '${_levelLabel(level)} ${counts[level] ?? 0}',
              selected: active,
              onSelected: () => onSelected(level),
              selectedColor: level == null ? Console.accent : levelColor(level),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _LogRow extends StatelessWidget {
  const _LogRow({required this.event});

  final LogEvent event;

  @override
  Widget build(BuildContext context) {
    final Color color = levelColor(event.level);
    return Semantics(
      button: true,
      label: 'Copy log entry',
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onLongPress: () async {
          await Clipboard.setData(
            ClipboardData(
              text:
                  '${formatDateTime(event.timestamp)} '
                  '[${event.level.name.toUpperCase()}] ${event.message}',
            ),
          );
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: Console.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Console.border),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Container(
                width: 3,
                height: 32,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Text(
                          formatClock(event.timestamp),
                          style: TextStyle(
                            color: Console.muted,
                            fontSize: 10,
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 8),
                        StatusPill(
                          label: event.level.name.toUpperCase(),
                          color: color,
                        ),
                        if (event.recordingId != null) ...<Widget>[
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              event.recordingId!.split('-').first,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Console.muted,
                                fontSize: 9,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      event.message,
                      style: TextStyle(
                        color: Console.textSoft,
                        fontSize: 11,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Color levelColor(LogLevel level) => switch (level) {
  LogLevel.info => Console.accent,
  LogLevel.warn => Console.amber,
  LogLevel.error => Console.red,
};

String _levelLabel(LogLevel? level) => switch (level) {
  null => 'ALL',
  LogLevel.info => 'INFO',
  LogLevel.warn => 'WARN',
  LogLevel.error => 'ERROR',
};
