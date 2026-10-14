import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../domain/recording.dart';
import '../domain/related_captures.dart';
import 'card_parts.dart';

/// A related capture resolved for display: the match and the capture it
/// points at. The host resolves it, so this widget never holds a controller.
class RelatedEntry {
  const RelatedEntry({required this.recording, required this.match});

  final Recording recording;
  final RelatedCapture match;
}

/// The editor's `RELATED` block (#272): other captures close in meaning to
/// this one, best first, each opening that capture. Read-only — it never
/// merges, closes or re-ranks anything.
class RelatedSection extends StatelessWidget {
  RelatedSection({super.key, required this.entries, required this.onOpen});

  static const String duplicateLabel = 'LIKELY DUPLICATE';

  final List<RelatedEntry> entries;
  final ValueChanged<Recording> onOpen;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SectionHeader(title: 'RELATED', trailing: '${entries.length}'),
        const SizedBox(height: 4),
        for (final RelatedEntry entry in entries)
          InkWell(
            onTap: () => onOpen(entry.recording),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
              child: Row(
                children: <Widget>[
                  Icon(Icons.link, size: 14, color: Console.muted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          displayNameFor(entry.recording),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: Console.text, fontSize: 12),
                        ),
                        Text(
                          formatDateTime(entry.recording.createdAt),
                          style: ConsoleText.micro,
                        ),
                      ],
                    ),
                  ),
                  if (entry.match.duplicate) ...<Widget>[
                    StatusPill(
                      label: duplicateLabel,
                      color: Console.amber,
                      outlined: true,
                    ),
                    const SizedBox(width: 8),
                  ],
                  Text(
                    '${(entry.match.score * 100).round()}%',
                    style: ConsoleText.micro.copyWith(color: Console.mutedSoft),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
