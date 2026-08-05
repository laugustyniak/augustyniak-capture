import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/ui_kit.dart';
import '../../recordings/domain/recording.dart';
import '../../recordings/presentation/handoff_sheet.dart';
import '../../recordings/presentation/recording_card.dart';
import '../../recordings/presentation/recording_editor.dart';
import '../../recordings/presentation/recordings_controller.dart';
import '../domain/project.dart';
import 'projects_controller.dart';

/// Modal bottom sheet showing all capture notes assigned to a specific project.
class ProjectCapturesSheet extends StatefulWidget {
  const ProjectCapturesSheet({
    super.key,
    required this.project,
    required this.recordingsController,
    this.projectsController,
    this.onNavigateToQueue,
  });

  final Project project;
  final RecordingsController recordingsController;
  final ProjectsController? projectsController;
  final ValueChanged<String>? onNavigateToQueue;

  @override
  State<ProjectCapturesSheet> createState() => _ProjectCapturesSheetState();
}

class _ProjectCapturesSheetState extends State<ProjectCapturesSheet> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  String? _editingId;

  List<String> _tagSuggestions(Recording current) {
    final Map<String, int> uses = <String, int>{};
    for (final Recording item in widget.recordingsController.recordings) {
      if (item.id == current.id) continue;
      for (final String tag in item.tags) {
        uses[tag] = (uses[tag] ?? 0) + 1;
      }
    }
    final List<String> values = uses.keys.toList()
      ..sort((String a, String b) => uses[b]!.compareTo(uses[a]!));
    return values;
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double maxHeight = MediaQuery.of(context).size.height * 0.85;
    final double bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return ListenableBuilder(
      listenable: widget.recordingsController,
      builder: (BuildContext context, Widget? child) {
        final List<Recording> allProjectCaptures = widget.recordingsController.recordings
            .where((Recording r) => r.projectId == widget.project.id)
            .toList();

        final String query = _searchQuery.trim().toLowerCase();
        final List<Recording> captures = query.isEmpty
            ? allProjectCaptures
            : allProjectCaptures.where((Recording r) {
                final String haystack = <String?>[
                  r.title,
                  r.transcript,
                  r.summary,
                  r.category?.name,
                  ...r.tags,
                ].whereType<String>().join(' ').toLowerCase();
                return haystack.contains(query);
              }).toList();

        return Container(
          constraints: BoxConstraints(maxHeight: maxHeight),
          decoration: BoxDecoration(
            color: Console.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
            border: Border(
              top: BorderSide(color: Console.borderStrong),
              left: BorderSide(color: Console.borderStrong),
              right: BorderSide(color: Console.borderStrong),
            ),
          ),
          padding: EdgeInsets.only(bottom: bottomInset),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              // Drag handle
              Center(
                child: Container(
                  margin: const EdgeInsets.only(top: 10, bottom: 6),
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Console.borderStrong,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              Text(
                                'PROJECT CAPTURES',
                                style: ConsoleText.chip.copyWith(
                                  fontSize: 11,
                                  letterSpacing: 1.1,
                                  color: Console.accent,
                                ),
                              ),
                              const SizedBox(width: 8),
                              StatusPill(
                                label: '${allProjectCaptures.length} ${allProjectCaptures.length == 1 ? 'ITEM' : 'ITEMS'}',
                                color: Console.accent,
                                outlined: true,
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            widget.project.name,
                            style: ConsoleText.cardTitle.copyWith(fontSize: 16),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            widget.project.repoPath,
                            style: ConsoleText.cardMeta,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    ConsoleIconButton(
                      icon: Icons.close_rounded,
                      semanticLabel: 'Close captures sheet',
                      onTap: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, thickness: 1),
              if (allProjectCaptures.length > 2) ...<Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 10, 18, 8),
                  child: ConsoleField(
                    controller: _searchController,
                    hintText: 'Search project captures...',
                    prefixIcon: Icon(
                      Icons.search_rounded,
                      size: 18,
                      color: Console.muted,
                    ),
                    onChanged: (String value) {
                      setState(() => _searchQuery = value);
                    },
                  ),
                ),
              ],
              Expanded(
                child: captures.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(18),
                        child: EmptyPanel(
                          icon: Icons.folder_open_outlined,
                          title: allProjectCaptures.isEmpty
                              ? 'No captures assigned yet.'
                              : 'No matching captures.',
                          blurb: allProjectCaptures.isEmpty
                              ? 'Captures routed or assigned to "${widget.project.name}" will appear here.'
                              : 'Try adjusting your search query.',
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(18, 10, 18, 20),
                        itemCount: captures.length,
                        itemBuilder: (BuildContext context, int index) {
                          final Recording recording = captures[index];
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 11),
                            child: recording.id == _editingId
                                ? RecordingEditor(
                                    recording: recording,
                                    revisions: widget.recordingsController
                                        .revisionsFor(recording.id),
                                    tagSuggestions: _tagSuggestions(recording),
                                    projects: widget.projectsController
                                            ?.projects ??
                                        const <Project>[],
                                    onTitleChanged: (String title) =>
                                        widget.recordingsController.setTitle(
                                      recording.id,
                                      title,
                                    ),
                                    onTextChanged: (String text) =>
                                        widget.recordingsController.editTranscript(
                                      recording.id,
                                      text,
                                    ),
                                    onCategoryChanged: (category) =>
                                        widget.recordingsController.setCategory(
                                      recording.id,
                                      category,
                                    ),
                                    onTagsChanged: (tags) =>
                                        widget.recordingsController.setTags(
                                      recording.id,
                                      tags,
                                    ),
                                    onProjectChanged: (projectId) =>
                                        widget.recordingsController.setProject(
                                      recording.id,
                                      projectId,
                                    ),
                                    onDelete: () async {
                                      await widget.recordingsController
                                          .deleteRecording(recording.id);
                                      setState(() => _editingId = null);
                                    },
                                    onDone: () =>
                                        setState(() => _editingId = null),
                                  )
                                : RecordingCard(
                                    recording: recording,
                                    isPlaying: widget.recordingsController
                                            .playingId ==
                                        recording.id,
                                    isEnriching: widget.recordingsController
                                        .isEnriching(recording.id),
                                    projectName: widget.project.name,
                                    canRoute: widget.recordingsController
                                        .canRoute(recording),
                                    onRoute: () => widget.recordingsController
                                        .route(recording.id),
                                    canHandoff: widget.recordingsController
                                        .canHandoff(recording),
                                    onHandoff: () => showHandoffSheet(
                                      context,
                                      controller: widget.recordingsController,
                                      recording: recording,
                                      projectName: widget.project.name,
                                    ),
                                    onTogglePlay: () => widget
                                        .recordingsController
                                        .togglePlayback(recording.id),
                                    onOpen: () => widget.recordingsController
                                        .openSource(recording.id),
                                    onRetry: () => widget.recordingsController
                                        .retryTranscription(recording.id),
                                    onEnrich: () => widget.recordingsController
                                        .retryEnrichment(recording.id),
                                    onEdit: () => setState(
                                      () => _editingId = recording.id,
                                    ),
                                    onToggleProcessed: () async {
                                      unawaited(
                                        HapticFeedback.selectionClick(),
                                      );
                                      await widget.recordingsController
                                          .toggleProcessed(recording.id);
                                    },
                                  ),
                          );
                        },
                      ),
              ),
              if (widget.onNavigateToQueue != null &&
                  allProjectCaptures.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 4, 18, 16),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      key: const ValueKey<String>('open-in-queue-btn'),
                      onPressed: () {
                        Navigator.of(context).pop();
                        widget.onNavigateToQueue!(widget.project.id);
                      },
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Console.accent,
                        side: BorderSide(color: Console.accent),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      icon: const Icon(Icons.format_list_bulleted_rounded,
                          size: 16),
                      label: const Text(
                        'VIEW ALL IN QUEUE TAB',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          letterSpacing: .5,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
