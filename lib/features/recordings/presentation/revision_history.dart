import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../domain/recording_revision.dart';

/// Collapsed-by-default list of everything that has been overwritten on one
/// item, newest first.
///
/// Collapsed because the surface it sits in is for editing and this is
/// reference material: an item re-run a few times would otherwise push the
/// controls off the screen. Inline rather than behind a dialog, in the place
/// where the question "what did this say before?" actually comes up.
///
/// Lives in its own file — not inside the editor — because it is the *reader's*
/// half of the change-history feature: it renders `RecordingRevision` rows and
/// mutates nothing.
class RevisionHistorySection extends StatefulWidget {
  const RevisionHistorySection({super.key, required this.revisions});

  /// What has been overwritten on this item, newest first. Empty on a capture
  /// that was processed once and never re-run, which is the common case — the
  /// section then draws nothing at all rather than an empty panel.
  final List<RecordingRevision> revisions;

  @override
  State<RevisionHistorySection> createState() => _RevisionHistorySectionState();
}

class _RevisionHistorySectionState extends State<RevisionHistorySection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    if (widget.revisions.isEmpty) return const SizedBox.shrink();
    final int count = widget.revisions.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Semantics(
          button: true,
          expanded: _expanded,
          child: InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: <Widget>[
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_down_rounded
                        : Icons.keyboard_arrow_right_rounded,
                    size: 16,
                    color: Console.muted,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: SectionHeader(
                      title: 'HISTORY',
                      trailing: '$count change${count == 1 ? '' : 's'}',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_expanded) ...<Widget>[
          const SizedBox(height: 6),
          // Bounded and independently scrollable: an item with a long history
          // must not be able to push the editor's own controls out of reach.
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260),
            child: ListView.separated(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: count,
              separatorBuilder: (BuildContext _, int _) =>
                  const SizedBox(height: 8),
              itemBuilder: (BuildContext _, int index) =>
                  _RevisionTile(revision: widget.revisions[index]),
            ),
          ),
        ],
      ],
    );
  }
}

class _RevisionTile extends StatelessWidget {
  const _RevisionTile({required this.revision});

  final RecordingRevision revision;

  /// Long enough to recognise a transcript, short enough that three entries
  /// still fit. The full value always goes to the clipboard button regardless.
  static const int _previewLength = 220;

  static String _preview(String? value) {
    if (value == null || value.isEmpty) return '—';
    final String collapsed = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (collapsed.length <= _previewLength) return collapsed;
    return '${collapsed.substring(0, _previewLength)}…';
  }

  @override
  Widget build(BuildContext context) {
    return ConsoleCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              StatusPill(
                label: revision.source.label,
                color: revision.source == RevisionSource.user
                    ? Console.muted
                    : Console.cyan,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${revision.field} · ${formatDateTime(revision.at)}',
                  style: ConsoleText.micro,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // The point of the whole feature: the overwritten value is the
              // one thing no longer reachable anywhere else, so it is what the
              // clipboard button hands back — in full, never the preview.
              if ((revision.from ?? '').isNotEmpty)
                CopyButton(
                  text: revision.from!,
                  tooltip: 'Copy the previous value',
                  semanticLabel: 'Copy the previous ${revision.field}',
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _preview(revision.from),
            style: ConsoleText.micro.copyWith(
              color: Console.textSoft,
              decoration: TextDecoration.lineThrough,
              decorationColor: Console.muted,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text('→ ', style: TextStyle(color: Console.muted)),
              Expanded(
                child: Text(
                  _preview(revision.to),
                  style: ConsoleText.micro.copyWith(color: Console.text),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
