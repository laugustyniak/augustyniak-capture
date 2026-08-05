import 'dart:io';

import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../domain/recording.dart';
import 'card_parts.dart';

/// Opens a dedicated focus view modal for reading and working with long
/// transcriptions in a spacious, selectable overlay.
Future<void> showTranscriptFocusModal(
  BuildContext context, {
  required Recording recording,
  String? projectName,
  VoidCallback? onEdit,
}) async {
  final String filename = File(recording.filePath).uri.pathSegments.last;
  final String displayName = displayNameFor(recording);
  final String transcript = (recording.transcript ?? '').trim();
  final int wordCount = transcript.isEmpty
      ? 0
      : transcript.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).length;
  final int charCount = transcript.length;

  await showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (BuildContext dialogContext) {
      final bool failed = recording.status == RecordingStatus.failed;
      return Dialog(
        backgroundColor: Console.surface,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: Console.borderStrong),
        ),
        child: Container(
          constraints: BoxConstraints(
            maxWidth: 680,
            maxHeight: MediaQuery.of(dialogContext).size.height * 0.85,
          ),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              // Header line with tile, title, pills, and close button.
              Row(
                children: <Widget>[
                  RecordingLeadingTile(
                    recording: recording,
                    failed: failed,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ConsoleText.cardTitle.copyWith(fontSize: 16),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          metaLineFor(recording, filename),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ConsoleText.cardMeta,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (projectName != null) ...<Widget>[
                    StatusPill(
                      label: projectName,
                      color: Console.mutedSoft,
                      outlined: true,
                    ),
                    const SizedBox(width: 6),
                  ],
                  if (recording.category != null)
                    StatusPill(
                      label: recording.category!.label,
                      color: categoryColorFor(recording.category),
                      outlined: true,
                    ),
                  const SizedBox(width: 10),
                  ConsoleIconButton(
                    icon: Icons.close_rounded,
                    onTap: () => Navigator.of(dialogContext).pop(),
                    semanticLabel: 'Close focus view',
                    size: 32,
                    iconSize: 18,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Divider(height: 1, color: Console.border),
              const SizedBox(height: 12),

              // Summary / tags if available
              if ((recording.summary ?? '').trim().isNotEmpty) ...<Widget>[
                Text(
                  recording.summary!.trim(),
                  style: ConsoleText.cardMeta.copyWith(color: Console.textSoft),
                ),
                const SizedBox(height: 10),
              ],

              // Words / Chars stats and copy affordance
              Row(
                children: <Widget>[
                  Text(
                    '$wordCount words · $charCount characters',
                    style: ConsoleText.micro.copyWith(color: Console.dimText),
                  ),
                  const Spacer(),
                  CopyButton(
                    text: transcript,
                    tooltip: 'Copy full text',
                    semanticLabel: 'Copy full text to clipboard',
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // Scrollable & Selectable text view
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Console.surfaceRaised,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Console.border),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      transcript,
                      style: ConsoleText.body.copyWith(
                        fontSize: 14,
                        height: 1.55,
                        color: Console.text,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),

              // Bottom actions bar
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  if (onEdit != null) ...<Widget>[
                    Semantics(
                      button: true,
                      label: 'Edit recording',
                      child: InkWell(
                        onTap: () {
                          Navigator.of(dialogContext).pop();
                          onEdit();
                        },
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 7,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Console.borderStrong),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Icon(
                                Icons.edit_outlined,
                                size: 13,
                                color: Console.text,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                'EDIT',
                                style: ConsoleText.chip.copyWith(
                                  color: Console.text,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                  ],
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    style: TextButton.styleFrom(
                      foregroundColor: Console.muted,
                    ),
                    child: const Text('CLOSE'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}
