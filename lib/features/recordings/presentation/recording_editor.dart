import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/ui_kit.dart';
import '../../projects/domain/project.dart';
import '../domain/capture_category.dart';
import '../domain/recording.dart';
import '../domain/recording_revision.dart';
import 'card_parts.dart';
import 'revision_history.dart';
import 'tag_editor.dart';

/// The queue row, in edit mode.
///
/// It replaces the bottom sheet that used to open over the list. A sheet meant
/// the item you were editing was hidden behind the thing editing it, every
/// field was a step removed from where it is normally read, and the four
/// changes it collected were committed in one lump at the end.
///
/// Here the row itself becomes the editor: same frame, same leading tile, same
/// durability footer, with the read-only lines swapped for controls. Nothing is
/// staged — **each field writes as soon as it is settled**, which is what the
/// four independent controller methods (`setTitle`, `editTranscript`,
/// `setCategory`, `setTags`) already described. There is therefore no SAVE:
/// [onDone] only closes the mode.
///
/// "Settled" differs by field, and deliberately:
/// - a chip (category, tag) writes on the tap — the tap *is* the decision;
/// - a text field writes when it loses focus or on Enter, because a keystroke
///   is not a decision, and one write per character would fill the change
///   history with rubbish.
///
/// A field the user has touched but not yet committed shows an amber `UNSAVED`
/// marker with a revert control next to it. That marker is the whole safety
/// net: without it, auto-save on blur would be indistinguishable from having
/// lost the edit.
class RecordingEditor extends StatefulWidget {
  const RecordingEditor({
    super.key,
    required this.recording,
    required this.revisions,
    required this.tagSuggestions,
    required this.onTitleChanged,
    required this.onTextChanged,
    required this.onCategoryChanged,
    required this.onTagsChanged,
    required this.onDone,
    this.onDelete,
    this.projects = const <Project>[],
    this.onProjectChanged,
  });

  /// Public so a test asserts on the same string the widget renders.
  static const String doneLabel = 'Finish editing';
  static const String deleteLabel = 'Delete this capture and its source file';
  static const String revertTitleLabel = 'Revert title to the saved value';
  static const String revertTextLabel = 'Revert text to the saved value';

  final Recording recording;
  final List<RecordingRevision> revisions;

  /// Tags used on other captures, offered as one-tap chips.
  final List<String> tagSuggestions;

  final ValueChanged<String> onTitleChanged;
  final ValueChanged<String> onTextChanged;
  final ValueChanged<CaptureCategory?> onCategoryChanged;
  final ValueChanged<List<String>> onTagsChanged;
  final VoidCallback onDone;

  /// Removes the capture for good. It lives here rather than on the card
  /// because the action strip there is play / edit / done — all cheap, all
  /// reversible — and an irreversible control a few pixels from `play` is the
  /// one mis-tap this app cannot undo.
  ///
  /// Reaching it costs one extra tap on the pencil, which is the whole idea.
  /// Null hides it entirely, so a host that has no deletion to offer renders
  /// the editor exactly as before.
  final VoidCallback? onDelete;

  /// Assignable projects. Empty hides the row entirely — an install that never
  /// defined one should not be shown a control with a single `—` in it.
  final List<Project> projects;
  final ValueChanged<String?>? onProjectChanged;

  @override
  State<RecordingEditor> createState() => _RecordingEditorState();
}

class _RecordingEditorState extends State<RecordingEditor> {
  late final TextEditingController _title = TextEditingController(
    text: _modelTitle,
  );
  late final TextEditingController _text = TextEditingController(
    text: _modelText,
  );
  final FocusNode _titleFocus = FocusNode();
  final FocusNode _textFocus = FocusNode();

  /// The last value this editor took *from* the item. Everything hangs off it:
  /// "dirty" is a difference from it, a revert restores it, and a commit is
  /// skipped when the field already equals it. It is not the same as
  /// `recording.title` — while the user is mid-edit the two deliberately differ.
  late String _syncedTitle = _modelTitle;
  late String _syncedText = _modelText;

  String get _modelTitle => widget.recording.title ?? '';
  String get _modelText => widget.recording.transcript ?? '';

  bool get _titleDirty => _title.text.trim() != _syncedTitle.trim();
  bool get _textDirty => _text.text.trim() != _syncedText.trim();

  @override
  void initState() {
    super.initState();
    _titleFocus.addListener(() {
      if (!_titleFocus.hasFocus) _commitTitle();
    });
    _textFocus.addListener(() {
      if (!_textFocus.hasFocus) _commitText();
    });
  }

  /// The item can change underneath an open editor — enrichment fills a blank
  /// title, a retry rewrites the transcript. Adopt the new value only when the
  /// field is clean; a field being typed into is the user's, and a background
  /// stage must never overwrite it mid-keystroke.
  @override
  void didUpdateWidget(RecordingEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_modelTitle != _syncedTitle && !_titleDirty) {
      _syncedTitle = _modelTitle;
      _title.text = _modelTitle;
    }
    if (_modelText != _syncedText && !_textDirty) {
      _syncedText = _modelText;
      _text.text = _modelText;
    }
  }

  @override
  void dispose() {
    // No commit-on-dispose: disposal happens on scroll-away and on rebuilds we
    // do not control, and a write from there would be invisible. DONE and blur
    // are the two commit points, and both are things the user did.
    _title.dispose();
    _text.dispose();
    _titleFocus.dispose();
    _textFocus.dispose();
    super.dispose();
  }

  void _commitTitle() {
    if (!_titleDirty) return;
    final String value = _title.text.trim();
    setState(() => _syncedTitle = value);
    widget.onTitleChanged(value);
  }

  void _commitText() {
    if (!_textDirty) return;
    final String value = _text.text.trim();
    // `editTranscript` refuses a blank edit so an item is never left textless.
    // Restoring the field is how that refusal becomes visible — otherwise the
    // editor would show an empty box that the item does not agree with.
    if (value.isEmpty) {
      _text.text = _syncedText;
      setState(() {});
      return;
    }
    setState(() => _syncedText = value);
    widget.onTextChanged(value);
  }

  void _revertTitle() {
    _title.text = _syncedTitle;
    setState(() {});
  }

  void _revertText() {
    _text.text = _syncedText;
    setState(() {});
  }

  /// Commits whatever is still pending, then hands control back. Reached by the
  /// DONE button and by Escape.
  void _finish() {
    _commitTitle();
    _commitText();
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final Recording recording = widget.recording;
    final String filename = File(recording.filePath).uri.pathSegments.last;

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): _finish,
      },
      // The binding above reacts only while focus is inside this subtree, and
      // opening the editor moves focus nowhere: the pencil is in the *card*,
      // which is replaced the moment the mode starts, and the title field is
      // deliberately not autofocused. So Escape used to work only after the
      // user had clicked into a text field — which made it look intermittent
      // rather than broken.
      //
      // The node goes on the shell, not on the title field, so the fix does not
      // reintroduce the blinking cursor that autofocusing a `TextField` would:
      // the container takes focus, no caret is drawn, and `pumpAndSettle` still
      // reaches a resting frame. It also gives the queue's own shortcut layer
      // somewhere to hand focus off to, so `e` cannot open a second editor
      // while this one is up.
      child: Focus(
        autofocus: true,
        child: RecordingCardShell(
          borderColor: Console.accent.withValues(alpha: .55),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  RecordingLeadingTile(
                    recording: recording,
                    failed: recording.status == RecordingStatus.failed,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Expanded(
                              child: ConsoleField(
                                controller: _title,
                                focusNode: _titleFocus,
                                // Deliberately *not* autofocused. Editing usually
                                // starts at a chip rather than at the name, and on
                                // a phone an automatic keyboard would cover the
                                // very row being edited. It also keeps a freshly
                                // opened editor free of a blinking cursor — an
                                // animation that never ends, which is the same
                                // trap PulseDot and ScanLine set for
                                // `pumpAndSettle`.
                                fontSize: 14,
                                hintText: filename,
                                textInputAction: TextInputAction.done,
                                onSubmitted: (String _) => _commitTitle(),
                                onChanged: (String _) => setState(() {}),
                              ),
                            ),
                            if (_titleDirty) ...<Widget>[
                              const SizedBox(width: 6),
                              _RevertButton(
                                semanticLabel: RecordingEditor.revertTitleLabel,
                                onTap: _revertTitle,
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 5),
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
                  StatusPill(label: 'EDITING', color: Console.accent),
                ],
              ),
              _EditorRule(),
              _Field(
                label: 'CATEGORY',
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: <Widget>[
                    // `—` and a real category mean different things on this item:
                    // null is "never classified", `capture` is "classified as
                    // unplaceable". The chip row keeps both reachable, which the
                    // dropdown did too — but here the whole vocabulary is visible
                    // at once instead of hidden behind a tap.
                    ConsoleChip(
                      label: '—',
                      selected: recording.category == null,
                      onSelected: () => widget.onCategoryChanged(null),
                    ),
                    for (final CaptureCategory value in CaptureCategory.values)
                      ConsoleChip(
                        label: value.label,
                        selected: recording.category == value,
                        onSelected: () => widget.onCategoryChanged(value),
                      ),
                  ],
                ),
              ),
              if (widget.projects.isNotEmpty && widget.onProjectChanged != null)
                _Field(
                  label: 'PROJECT',
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: <Widget>[
                      ConsoleChip(
                        label: '—',
                        selected: recording.projectId == null,
                        onSelected: () => widget.onProjectChanged!(null),
                      ),
                      for (final Project project in widget.projects)
                        ConsoleChip(
                          label: project.name,
                          selected: recording.projectId == project.id,
                          onSelected: () =>
                              widget.onProjectChanged!(project.id),
                        ),
                    ],
                  ),
                ),
              _Field(
                label: 'TAGS',
                child: TagEditor(
                  tags: recording.tags,
                  suggestions: widget.tagSuggestions,
                  onChanged: widget.onTagsChanged,
                ),
              ),
              _Field(
                label: 'TEXT',
                dirty: _textDirty,
                onRevert: _revertText,
                revertSemanticLabel: RecordingEditor.revertTextLabel,
                child: ConsoleField(
                  controller: _text,
                  focusNode: _textFocus,
                  minLines: 4,
                  maxLines: 12,
                  hintText: 'Transcript / OCR text / note',
                  onChanged: (String _) => setState(() {}),
                ),
              ),
              if (widget.revisions.isNotEmpty) ...<Widget>[
                const SizedBox(height: 4),
                RevisionHistorySection(revisions: widget.revisions),
              ],
              _EditorRule(),
              Row(
                children: <Widget>[
                  Expanded(child: VerificationLine(recording: recording)),
                  const SizedBox(width: 8),
                  if (widget.onDelete != null) ...<Widget>[
                    _DeleteButton(onTap: widget.onDelete!),
                    const SizedBox(width: 7),
                  ],
                  _DoneButton(onTap: _finish),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One labelled control in the editor.
///
/// The label sits in a fixed left column on a wide row and above the control on
/// a narrow one. Same widget either way: the app is desktop-first, where the
/// column reads as a form, but a phone-width card has no 84 px to spare and
/// would squeeze every chip row into three lines.
class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.child,
    this.dirty = false,
    this.onRevert,
    this.revertSemanticLabel,
  });

  static const double _labelColumn = 84;
  static const double _wideEnough = 460;

  final String label;
  final Widget child;
  final bool dirty;
  final VoidCallback? onRevert;
  final String? revertSemanticLabel;

  Widget _label() {
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        Text(
          label,
          style: ConsoleText.chip.copyWith(
            color: dirty ? Console.amber : Console.dimText,
            letterSpacing: 1.1,
          ),
        ),
        if (dirty) ...<Widget>[
          Text(
            'UNSAVED',
            style: ConsoleText.micro.copyWith(color: Console.amber),
          ),
          if (onRevert != null) ...<Widget>[
            _RevertButton(
              semanticLabel: revertSemanticLabel ?? 'Revert $label',
              onTap: onRevert!,
            ),
          ],
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          if (constraints.maxWidth < _wideEnough) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[_label(), const SizedBox(height: 7), child],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(
                width: _labelColumn,
                child: Padding(
                  padding: const EdgeInsets.only(top: 9),
                  child: _label(),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(child: child),
            ],
          );
        },
      ),
    );
  }
}

/// Puts a text field back to the value the item actually holds. Only ever
/// visible while that differs from what is typed, so it can never be mistaken
/// for a general undo.
class _RevertButton extends StatelessWidget {
  const _RevertButton({required this.semanticLabel, required this.onTap});

  final String semanticLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: InkResponse(
        onTap: onTap,
        radius: 16,
        child: Padding(
          padding: EdgeInsets.all(3),
          child: Icon(Icons.undo_rounded, size: 14, color: Console.amber),
        ),
      ),
    );
  }
}

/// Removes the capture for good. Shaped like [_DoneButton] so the strip stays
/// one row of controls, and coloured red so the difference is the colour rather
/// than the position — the confirmation dialog behind it is what actually
/// guards the action.
class _DeleteButton extends StatelessWidget {
  const _DeleteButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: RecordingEditor.deleteLabel,
      // The word inside the button is "DELETE", which on its own says neither
      // what is deleted nor that the file goes with it. Excluding the children
      // makes the node announce the full sentence instead of appending the
      // shorthand to it.
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Console.red.withValues(alpha: .4)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.delete_outline_rounded,
                size: 13,
                color: Console.redSoft,
              ),
              const SizedBox(width: 6),
              Text(
                'DELETE',
                style: ConsoleText.chip.copyWith(color: Console.redSoft),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Leaves edit mode. Says DONE rather than SAVE on purpose: every field has
/// already been written, and calling it SAVE would imply the edits were waiting
/// on this button — which is exactly the thing that made a lost sheet lose work.
class _DoneButton extends StatelessWidget {
  const _DoneButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: RecordingEditor.doneLabel,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
          decoration: BoxDecoration(
            color: Console.accent.withValues(alpha: .16),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Console.accent.withValues(alpha: .45)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.check_rounded, size: 13, color: Console.accent),
              const SizedBox(width: 6),
              Text(
                'DONE',
                style: ConsoleText.chip.copyWith(color: Console.accent),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Hairline between the editor's regions. Full-bleed inside the card padding,
/// which is what makes the mode read as a panel rather than as a taller card.
class _EditorRule extends StatelessWidget {
  const _EditorRule();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 12),
      child: SizedBox(
        height: 1,
        child: DecoratedBox(
          decoration: BoxDecoration(color: Console.border),
          child: SizedBox.expand(),
        ),
      ),
    );
  }
}
