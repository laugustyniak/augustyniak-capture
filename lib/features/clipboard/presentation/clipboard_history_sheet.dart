import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/ui_kit.dart';
import '../../recordings/domain/capture_type.dart';
import '../../recordings/presentation/recordings_controller.dart';
import '../domain/clipboard_item.dart';
import '../domain/clipboard_watcher_service.dart';

/// Clipboard history as a **list beside a preview**, not a list of expanding
/// rows.
///
/// The previous shape put three icon buttons — convert, collect, delete — on
/// every row, beside a three-line excerpt whose height changed with its content
/// and jumped again for an image thumbnail. Three problems came out of that
/// arrangement and all three are fixed by moving the work off the row:
///
/// - **The row was four targets wide.** Tapping a row pastes and closes the
///   sheet, and `delete` sat about 20 px from it. There is no undo for a
///   clipboard entry, so that was the one irreversible control on the screen
///   parked next to the one the user reaches for every time.
/// - **The list could not be scanned.** Rows were 90–160 px tall depending on
///   what happened to be in them, so five entries filled the sheet and finding
///   the right one meant scrolling past the content instead of past the titles.
/// - **Nothing showed what would actually be pasted.** The excerpt was clipped
///   at three lines with no way to see the rest, which is exactly the moment a
///   user wants to check they are about to paste the right token.
///
/// So the list stays narrow, fixed-height and scannable, and the whole of the
/// selected entry — plus every action on it — lives in one pane beside it. Below
/// [Console.compactBreakpoint] the same pane moves under the list rather than
/// beside it; it is the same widget either way, so a phone and a desktop cannot
/// offer different actions.
class ClipboardHistorySheet extends StatefulWidget {
  const ClipboardHistorySheet({
    super.key,
    required this.watcherService,
    this.recordingsController,
    this.onConvertText,
    this.onConvertImage,
    this.isModal = true,
  });

  final ClipboardWatcherService watcherService;
  final RecordingsController? recordingsController;
  final Future<void> Function(String text)? onConvertText;
  final Future<void> Function(File image)? onConvertImage;

  /// Whether this is the hotkey-invoked sheet rather than the Clipboard tab.
  ///
  /// It governs two things that only make sense for a sheet, and the second one
  /// was a real defect. A **drag handle** on a tab body promises a gesture that
  /// goes nowhere. And **autofocusing the search box** is right for a sheet the
  /// user opened by pressing a key — they are already typing — but wrong for a
  /// tab, because the shell keeps all six tabs alive inside an `IndexedStack`:
  /// every one of them is built at start-up, this one is built *after* the
  /// Queue, and the last `autofocus` registered with the route's `FocusScope`
  /// wins. So an off-screen search field took the focus that `_QueueShortcuts`
  /// needs, and every queue shortcut was dead until the user clicked something.
  final bool isModal;

  /// Taken from the widget by the tests rather than retyped, so the two panes
  /// stay locatable if either is renamed.
  static const Key listKey = ValueKey<String>('clipboard-list');
  static const Key previewKey = ValueKey<String>('clipboard-preview');

  @override
  State<ClipboardHistorySheet> createState() => _ClipboardHistorySheetState();
}

class _ClipboardHistorySheetState extends State<ClipboardHistorySheet> {
  /// Every row is exactly this tall, which is what makes both the scannable
  /// list and [_scrollToSelected] honest — the previous version scrolled by a
  /// hard-coded 72 px through rows that were anywhere between 90 and 160.
  static const double _rowHeight = 58;

  /// Below this the preview moves under the list instead of beside it. It is
  /// [Console.compactBreakpoint], so the sheet switches form at the same width
  /// the shell does.
  static const double _twoPaneWidth = Console.compactBreakpoint;

  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _keyboardFocus = FocusNode(debugLabel: 'clipboard-keys');

  String _filter = '';
  String? _selectedCollection;

  /// An **id, not an index** — the same rule the queue's `focusedId` follows.
  /// The list re-filters as the user types and re-orders as new entries arrive,
  /// and an index would silently move the selection onto whatever slid into
  /// that slot. Null means "nothing chosen yet", which resolves to the newest
  /// entry rather than to an empty pane.
  String? _selectedId;

  /// Inline confirmation for the tab form, where there is no sheet to close and
  /// the app uses no snackbars. Cleared by the next selection change.
  String? _handoffNotice;

  /// The entry being edited, or null. An **id, not the item**, for the same
  /// reason [_selectedId] is one — and it lives here rather than in
  /// [_ClipboardPreview] because changing the selection has to be able to flush
  /// a pending edit, which a parent cannot do by reaching into a child's state.
  String? _editingId;

  final TextEditingController _editController = TextEditingController();

  /// The last value taken **from the entry**. `dirty` is a difference from
  /// this, exactly as `_syncedText` works in `RecordingEditor`.
  String _syncedText = '';

  bool get _isEditDirty => _editController.text != _syncedText;

  /// The last dirty state the screen was built with. Typing has to reach the
  /// `UNSAVED` marker, but only the **transition** is worth a rebuild — a
  /// `setState` per keystroke would rebuild the list beside the field as well.
  bool _dirtyShown = false;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _editController.addListener(_onEditChanged);
  }

  void _onSearchChanged() {
    setState(() => _filter = _searchController.text.trim().toLowerCase());
  }

  void _onEditChanged() {
    if (_editingId == null) return;
    if (_isEditDirty == _dirtyShown) return;
    setState(() => _dirtyShown = _isEditDirty);
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _scrollController.dispose();
    _keyboardFocus.dispose();
    _editController.removeListener(_onEditChanged);
    _editController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- selection

  List<ClipboardItem> _visibleItems(List<ClipboardItem> all) {
    return all.where((ClipboardItem item) {
      if (_selectedCollection != null &&
          !item.collections.contains(_selectedCollection)) {
        return false;
      }
      if (_filter.isEmpty) return true;
      return (item.text ?? '').toLowerCase().contains(_filter);
    }).toList();
  }

  /// The chosen entry, or the newest one if the choice no longer resolves —
  /// which happens on every search keystroke and every eviction from the
  /// capped history.
  ClipboardItem? _selectedIn(List<ClipboardItem> visible) {
    if (visible.isEmpty) return null;
    for (final ClipboardItem item in visible) {
      if (item.id == _selectedId) return item;
    }
    return visible.first;
  }

  void _move(List<ClipboardItem> visible, int delta) {
    if (visible.isEmpty) return;
    final ClipboardItem? current = _selectedIn(visible);
    final int index = current == null
        ? 0
        : visible.indexWhere((ClipboardItem item) => item.id == current.id);
    final int next = (index + delta).clamp(0, visible.length - 1);
    unawaited(_select(visible[next].id));
    _scrollToSelected(next);
  }

  void _scrollToSelected(int index) {
    if (!_scrollController.hasClients) return;
    final double target = (index * _rowHeight).clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );
    _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOutCubic,
    );
  }

  /// Arrows and Enter only.
  ///
  /// The preview's other three actions deliberately advertise no shortcut. The
  /// search box is autofocused, so `EditableText` consumes anything that could
  /// plausibly bind to them — `Ctrl+Backspace` deletes a word before this
  /// listener ever sees it — and a key hint printed on a button that cannot fire
  /// is indistinguishable from a shortcut the OS refused, which is the failure
  /// this app keeps designing against.
  ///
  /// **While an entry is being edited this listener stands down entirely**,
  /// Escape excepted. `KeyboardListener` wraps the whole sheet and sees a key
  /// before the focused field's own text handling does, so without the guard
  /// Enter pasted the entry's *pre-edit* text, popped the route and auto-pasted
  /// it into the app underneath — losing the typing on the way out — and the
  /// arrows made the caret unreachable by jumping to another entry instead.
  void _handleKey(KeyEvent event, List<ClipboardItem> visible) {
    if (_editingId != null) {
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.escape) {
        unawaited(_endEdit());
      }
      return;
    }
    if (event is! KeyDownEvent) return;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _move(visible, 1);
    } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _move(visible, -1);
    } else if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      final ClipboardItem? item = _selectedIn(visible);
      if (item != null) _paste(context, item);
    }
  }

  // ------------------------------------------------------------------ actions

  Future<void> _paste(BuildContext context, ClipboardItem item) async {
    await widget.watcherService.copyToClipboard(item);
    if (!context.mounted) return;
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
    await widget.watcherService.pasteToActiveApp();
  }

  bool _canConvert(ClipboardItem item) {
    if (item.type == ClipboardItemType.image) {
      return item.imagePath != null &&
          (widget.onConvertImage != null || widget.recordingsController != null);
    }
    return (item.text ?? '').trim().isNotEmpty &&
        (widget.onConvertText != null || widget.recordingsController != null);
  }

  Future<void> _convertToCapture(
    BuildContext context,
    ClipboardItem item,
  ) async {
    if (item.type == ClipboardItemType.image && item.imagePath != null) {
      final File image = File(item.imagePath!);
      if (!await image.exists()) return;
      if (widget.onConvertImage != null) {
        await widget.onConvertImage!(image);
      } else {
        await widget.recordingsController!.addImportedFile(
          image,
          CaptureType.image,
        );
      }
      if (context.mounted) _confirmHandoff(context, 'Image sent to OCR');
      return;
    }
    final String text = item.text ?? '';
    if (text.trim().isEmpty) return;
    if (widget.onConvertText != null) {
      await widget.onConvertText!(text);
    } else {
      await widget.recordingsController!.addTextNote(text);
    }
    if (context.mounted) _confirmHandoff(context, 'Sent to the capture queue');
  }

  /// Closes the sheet if it is one, because the capture it just created is in
  /// the queue behind it.
  void _confirmHandoff(BuildContext context, String message) {
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _handoffNotice = message);
  }

  Future<void> _delete(ClipboardItem item, List<ClipboardItem> visible) async {
    // Move the selection off the row before it disappears, so the pane shows
    // the next entry rather than snapping back to the top of the list.
    final int index = visible.indexWhere((ClipboardItem e) => e.id == item.id);
    final ClipboardItem? next = index >= 0 && index + 1 < visible.length
        ? visible[index + 1]
        : (index > 0 ? visible[index - 1] : null);
    setState(() => _selectedId = next?.id);
    await widget.watcherService.deleteItem(item.id);
  }

  Future<void> _clearAll(BuildContext context) async {
    final bool confirmed = await confirmDestructive(
      context,
      title: 'Clear the clipboard history?',
      message:
          'Every entry is removed, including the images copied into the app '
          'folder. Nothing here is recoverable afterwards.',
      confirmLabel: 'CLEAR',
    );
    if (!confirmed) return;
    setState(() => _selectedId = null);
    await widget.watcherService.clearHistory();
  }

  Future<void> _promptNewCollection(BuildContext context) async {
    final TextEditingController nameController = TextEditingController();
    final String? name = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => ConsolePaletteScope(
        builder: (BuildContext context) => AlertDialog(
          backgroundColor: Console.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(color: Console.border),
          ),
          title: Text(
            'New collection',
            style: TextStyle(
              fontFamily: ConsoleFont.display,
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Console.text,
            ),
          ),
          content: TextField(
            controller: nameController,
            autofocus: true,
            style: TextStyle(color: Console.text),
            onSubmitted: (String value) {
              if (value.trim().isNotEmpty) {
                Navigator.of(context).pop(value.trim());
              }
            },
            decoration: InputDecoration(
              hintText: 'Name (Prompts, Snippets, …)',
              hintStyle: TextStyle(color: Console.dimText),
              filled: true,
              fillColor: Console.surfaceRaised,
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('CANCEL'),
            ),
            TextButton(
              onPressed: () {
                final String value = nameController.text.trim();
                if (value.isNotEmpty) Navigator.of(context).pop(value);
              },
              child: const Text('ADD'),
            ),
          ],
        ),
      ),
    );
    if (name != null && name.isNotEmpty) {
      setState(() => _selectedCollection = name);
    }
  }

  Future<void> _manageCollections(
    BuildContext context,
    ClipboardItem item,
  ) async {
    final Set<String> suggestions = <String>{
      'Favourites',
      'Snippets',
      'Prompts',
      ...widget.watcherService.allCollections,
    };

    await showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext context) => ConsolePaletteScope(
        builder: (BuildContext context) => ListenableBuilder(
          listenable: widget.watcherService,
          builder: (BuildContext context, Widget? child) {
            final ClipboardItem live = widget.watcherService.items.firstWhere(
              (ClipboardItem e) => e.id == item.id,
              orElse: () => item,
            );
            return Container(
              padding: const EdgeInsets.all(20),
              color: Console.surface,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SectionHeader(title: 'COLLECTIONS'),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: suggestions
                        .map(
                          (String name) => ConsoleChip(
                            label: name,
                            selected: live.collections.contains(name),
                            onSelected: () => widget.watcherService
                                .toggleItemCollection(live.id, name),
                          ),
                        )
                        .toList(),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ editing

  void _startEdit(ClipboardItem item) {
    setState(() {
      _editingId = item.id;
      _syncedText = item.text ?? '';
      _editController.text = _syncedText;
      _dirtyShown = false;
      _handoffNotice = null;
    });
  }

  /// Writes the pending text if there is any worth writing.
  ///
  /// Blank is not an edit: an entry with no body cannot be pasted or searched,
  /// and deletion has its own action.
  Future<void> _commitEdit() async {
    final String? id = _editingId;
    if (id == null || !_isEditDirty) return;
    final String text = _editController.text;
    if (text.trim().isEmpty) return;
    _syncedText = text;
    await widget.watcherService.updateItemText(id, text);
    // The field is clean again, so the marker goes with it — this is the path a
    // focus loss takes, which reaches no other `setState`.
    if (mounted) setState(() => _dirtyShown = _isEditDirty);
  }

  Future<void> _endEdit() async {
    await _commitEdit();
    if (!mounted) return;
    setState(() => _editingId = null);
  }

  void _revertEdit() {
    setState(() {
      _editController.text = _syncedText;
      _dirtyShown = false;
    });
  }

  /// Selection changes go through here so a pending edit is never lost.
  Future<void> _select(String id) async {
    await _endEdit();
    if (!mounted) return;
    setState(() {
      _selectedId = id;
      _handoffNotice = null;
    });
  }

  // -------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.watcherService,
      builder: (BuildContext context, Widget? child) {
        final List<ClipboardItem> all = widget.watcherService.items;
        final List<ClipboardItem> visible = _visibleItems(all);
        final ClipboardItem? selected = _selectedIn(visible);

        return KeyboardListener(
          focusNode: _keyboardFocus,
          onKeyEvent: (KeyEvent event) => _handleKey(event, visible),
          child: Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.88,
            ),
            // Sheet chrome only when it is a sheet: rounded at the top and
            // open at the bottom is how a modal meets the screen edge, and as a
            // tab it left the panel visibly unfinished above the page.
            decoration: BoxDecoration(
              color: Console.surface,
              borderRadius: widget.isModal
                  ? const BorderRadius.vertical(top: Radius.circular(20))
                  : BorderRadius.circular(16),
              border: widget.isModal
                  ? Border(
                      top: BorderSide(color: Console.borderStrong),
                      left: BorderSide(color: Console.borderStrong),
                      right: BorderSide(color: Console.borderStrong),
                    )
                  : Border.all(color: Console.border),
            ),
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (widget.isModal) ...<Widget>[
                    const SizedBox(height: 12),
                    Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Console.borderStrong,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  _Header(
                    total: all.length,
                    onClear: all.isEmpty ? null : () => _clearAll(context),
                  ),
                  const SizedBox(height: 12),
                  _Filters(
                    autofocus: widget.isModal,
                    searchController: _searchController,
                    query: _filter,
                    collections: widget.watcherService.allCollections,
                    selectedCollection: _selectedCollection,
                    onCollectionChanged: (String? value) =>
                        setState(() => _selectedCollection = value),
                    onNewCollection: () => _promptNewCollection(context),
                  ),
                  const SizedBox(height: 10),
                  Divider(height: 1, color: Console.border),
                  Expanded(
                    child: LayoutBuilder(
                      builder:
                          (BuildContext context, BoxConstraints constraints) {
                            final Widget list = _buildList(visible, selected);
                            final Widget preview = _buildPreview(
                              visible,
                              selected,
                              empty: all.isEmpty,
                            );

                            if (constraints.maxWidth >= _twoPaneWidth) {
                              return Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: <Widget>[
                                  SizedBox(width: 282, child: list),
                                  VerticalDivider(
                                    width: 1,
                                    color: Console.border,
                                  ),
                                  Expanded(child: preview),
                                ],
                              );
                            }
                            return Column(
                              children: <Widget>[
                                Expanded(child: list),
                                Divider(height: 1, color: Console.border),
                                SizedBox(
                                  // Just under half: enough to read a token or
                                  // a command back and still see which row in
                                  // the list it came from.
                                  height: constraints.maxHeight * .45,
                                  child: preview,
                                ),
                              ],
                            );
                          },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildList(List<ClipboardItem> visible, ClipboardItem? selected) {
    if (visible.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            _filter.isEmpty && _selectedCollection == null
                ? 'The clipboard history is empty.'
                : 'Nothing matches this collection or search.',
            textAlign: TextAlign.center,
            style: ConsoleText.body,
          ),
        ),
      );
    }
    return ListView.builder(
      key: ClipboardHistorySheet.listKey,
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: visible.length,
      itemExtent: _rowHeight,
      itemBuilder: (BuildContext context, int index) {
        final ClipboardItem item = visible[index];
        return _ClipboardListRow(
          item: item,
          timeLabel: formatClipboardAge(item.copiedAt),
          selected: item.id == selected?.id,
          onTap: () => _select(item.id),
        );
      },
    );
  }

  Widget _buildPreview(
    List<ClipboardItem> visible,
    ClipboardItem? selected, {
    required bool empty,
  }) {
    if (selected == null) {
      // Scrollable rather than centred alone: in the stacked form the pane is
      // 45 % of the sheet, which on a short phone is less than the panel is
      // tall.
      return SingleChildScrollView(
        padding: const EdgeInsets.all(18),
        child: EmptyPanel(
          icon: Icons.content_paste_off_rounded,
          title: empty
              ? 'Nothing copied yet.'
              : 'No entry matches the filters.',
          blurb: empty
              ? 'Anything you copy while the app is running lands here, ready '
                    'to paste back or hand to the capture queue.'
              : 'Clear the search or pick another collection.',
        ),
      );
    }
    return _ClipboardPreview(
      key: ClipboardHistorySheet.previewKey,
      item: selected,
      notice: _handoffNotice,
      onPaste: () => _paste(context, selected),
      onConvert: _canConvert(selected)
          ? () => _convertToCapture(context, selected)
          : null,
      onCollections: () => _manageCollections(context, selected),
      onDelete: () => _delete(selected, visible),
      editing: _editingId == selected.id,
      editController: _editController,
      dirty: _isEditDirty,
      onEdit: () => _startEdit(selected),
      onEndEdit: () => unawaited(_endEdit()),
      onRevert: _revertEdit,
      onEditFocusLost: () => unawaited(_commitEdit()),
    );
  }
}

/// `15h · text`. Exposed for the row and for the preview so the two cannot
/// disagree about how old an entry is.
String formatClipboardAge(DateTime copiedAt) {
  final Duration diff = DateTime.now().difference(copiedAt);
  if (diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  return '${copiedAt.day}.${copiedAt.month.toString().padLeft(2, '0')} '
      '${copiedAt.hour.toString().padLeft(2, '0')}:'
      '${copiedAt.minute.toString().padLeft(2, '0')}';
}

class _Header extends StatelessWidget {
  _Header({required this.total, required this.onClear});

  final int total;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: <Widget>[
          Icon(Icons.content_paste_rounded, color: Console.accent, size: 20),
          const SizedBox(width: 10),
          Text(
            'CLIPBOARD',
            style: TextStyle(
              fontFamily: ConsoleFont.display,
              fontWeight: FontWeight.bold,
              fontSize: 16,
              letterSpacing: 1.1,
              color: Console.text,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            '$total ${total == 1 ? 'entry' : 'entries'}',
            style: ConsoleText.counter,
          ),
          const Spacer(),
          if (onClear != null)
            TextButton(
              onPressed: onClear,
              style: TextButton.styleFrom(foregroundColor: Console.red),
              child: Text('CLEAR ALL', style: ConsoleText.chip),
            ),
        ],
      ),
    );
  }
}

/// Search and the collection chips — one strip, the same shape the Queue's
/// toolbar uses, because they answer the same question: what does this list
/// currently hold.
///
/// The chips list the collections that **exist**, not a fixed vocabulary. The
/// previous version always offered three built-in names, so tapping one of them
/// on a fresh install emptied the list with no way to tell that the collection
/// itself was empty rather than the filter broken.
class _Filters extends StatelessWidget {
  _Filters({
    required this.autofocus,
    required this.searchController,
    required this.query,
    required this.collections,
    required this.selectedCollection,
    required this.onCollectionChanged,
    required this.onNewCollection,
  });

  final bool autofocus;
  final TextEditingController searchController;
  final String query;
  final Set<String> collections;
  final String? selectedCollection;
  final ValueChanged<String?> onCollectionChanged;
  final VoidCallback onNewCollection;

  @override
  Widget build(BuildContext context) {
    final Widget search = TextField(
      controller: searchController,
      autofocus: autofocus,
      style: TextStyle(color: Console.text, fontSize: 13),
      decoration: InputDecoration(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(vertical: 11),
        hintText: 'Search the clipboard  ·  ↑ ↓ to move, ⏎ to paste',
        hintStyle: TextStyle(color: Console.dimText, fontSize: 13),
        prefixIcon: Icon(Icons.search, color: Console.dimText, size: 18),
        prefixIconConstraints: const BoxConstraints(minWidth: 38),
        suffixIcon: query.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear search',
                constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                padding: EdgeInsets.zero,
                icon: Icon(Icons.close, color: Console.dimText, size: 18),
                onPressed: searchController.clear,
              ),
        filled: true,
        fillColor: Console.surfaceRaised,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: Console.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: Console.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: Console.accent),
        ),
      ),
    );

    final Widget chips = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: <Widget>[
          ConsoleChip(
            label: 'ALL',
            selected: selectedCollection == null,
            onSelected: () => onCollectionChanged(null),
          ),
          for (final String name in collections) ...<Widget>[
            const SizedBox(width: 6),
            ConsoleChip(
              label: name,
              selected: selectedCollection == name,
              onSelected: () => onCollectionChanged(name),
            ),
          ],
          const SizedBox(width: 6),
          ConsoleIconButton(
            icon: Icons.add_rounded,
            semanticLabel: 'New collection',
            onTap: onNewCollection,
            size: 32,
            iconSize: 16,
          ),
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          if (constraints.maxWidth < 520) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[search, const SizedBox(height: 10), chips],
            );
          }
          return Row(
            children: <Widget>[
              Expanded(child: search),
              const SizedBox(width: 10),
              Flexible(child: chips),
            ],
          );
        },
      ),
    );
  }
}

/// One fixed-height row: type glyph, a single line of content, age and kind.
///
/// Deliberately carries **no action button**. Every row in a clipboard history
/// looks like every other one, and the entry the user wants is identified by
/// reading it — so the row's only job is to be readable at a glance and to be
/// selectable, and the irreversible control lives one pane away.
class _ClipboardListRow extends StatelessWidget {
  _ClipboardListRow({
    required this.item,
    required this.timeLabel,
    required this.selected,
    required this.onTap,
  });

  final ClipboardItem item;
  final String timeLabel;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bool isImage = item.type == ClipboardItemType.image;
    final String line = _firstLine(item);
    final Color glyph = isImage ? Console.pink : Console.accent;

    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: selected
                ? Console.accent.withValues(alpha: .12)
                : Colors.transparent,
            border: Border(
              left: BorderSide(
                color: selected ? Console.accent : Colors.transparent,
                width: 2,
              ),
              bottom: BorderSide(color: Console.border.withValues(alpha: .5)),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(12, 9, 14, 9),
          child: Row(
            children: <Widget>[
              Icon(
                isImage ? Icons.image_rounded : Icons.notes_rounded,
                size: 16,
                color: selected ? glyph : Console.dim,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Text(
                      line,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: ConsoleFont.mono,
                        fontSize: 12,
                        color: selected ? Console.text : Console.textSoft,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      <String>[
                        timeLabel,
                        isImage ? 'image' : 'text',
                        ...item.collections,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ConsoleText.micro,
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

/// The whole of the selected entry, plus every action on it.
class _ClipboardPreview extends StatelessWidget {
  _ClipboardPreview({
    super.key,
    required this.item,
    required this.onPaste,
    required this.onConvert,
    required this.onCollections,
    required this.onDelete,
    required this.editing,
    required this.editController,
    required this.dirty,
    required this.onEdit,
    required this.onEndEdit,
    required this.onRevert,
    required this.onEditFocusLost,
    this.notice,
  });

  final ClipboardItem item;
  final VoidCallback onPaste;
  final VoidCallback? onConvert;
  final VoidCallback onCollections;
  final VoidCallback onDelete;

  /// The edit mode is driven from [_ClipboardHistorySheetState], which is what
  /// lets a selection change flush a pending edit before it moves on. This
  /// widget stays stateless and only renders what it is handed.
  final bool editing;
  final TextEditingController editController;
  final bool dirty;
  final VoidCallback onEdit;
  final VoidCallback onEndEdit;
  final VoidCallback onRevert;
  final VoidCallback onEditFocusLost;

  /// Inline confirmation shown after a hand-off, because the app uses no
  /// snackbars and the tab form has no sheet to close as its receipt.
  final String? notice;

  @override
  Widget build(BuildContext context) {
    final bool isImage = item.type == ClipboardItemType.image;
    final String text = item.text ?? '';

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(_metaLine(item), style: ConsoleText.micro),
                    const SizedBox(height: 4),
                    Text(
                      _firstLine(item),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: ConsoleFont.display,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: Console.text,
                      ),
                    ),
                  ],
                ),
              ),
              if (!isImage && text.isNotEmpty) ...<Widget>[
                const SizedBox(width: 10),
                // Copy without pasting: the primary action closes the sheet and
                // types into whatever had focus, which is not always what is
                // wanted.
                CopyButton(text: text, tooltip: 'Copy without pasting'),
              ],
              if (editing && dirty) ...<Widget>[
                const SizedBox(width: 10),
                // Same marker as `RecordingEditor` in the Queue, down to the
                // token: a plain amber micro label, not a StatusPill, because a
                // pill would read as a state of the entry rather than a warning
                // about the field.
                Text(
                  'UNSAVED',
                  style: ConsoleText.micro.copyWith(color: Console.amber),
                ),
                const SizedBox(width: 4),
                ConsoleIconButton(
                  icon: Icons.undo_rounded,
                  semanticLabel: 'Revert the edit',
                  onTap: onRevert,
                  size: 30,
                  iconSize: 15,
                ),
              ],
            ],
          ),
          if (item.collections.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: item.collections
                  .map(
                    (String name) => StatusPill(
                      label: name.toUpperCase(),
                      color: Console.accent,
                      outlined: true,
                    ),
                  )
                  .toList(),
            ),
          ],
          const SizedBox(height: 12),
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: Console.surfaceDeep,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Console.border),
              ),
              padding: const EdgeInsets.all(14),
              child: isImage && item.imagePath != null
                  ? Center(
                      child: Image.file(
                        File(item.imagePath!),
                        fit: BoxFit.contain,
                        errorBuilder:
                            (
                              BuildContext context,
                              Object error,
                              StackTrace? stack,
                            ) => Text(
                              'The image file is gone from disk.',
                              style: ConsoleText.body.copyWith(
                                color: Console.redSoft,
                              ),
                            ),
                      ),
                    )
                  : editing
                  // Committing on focus loss is what makes a SAVE button
                  // unnecessary: leaving the field is the gesture that writes.
                  ? Focus(
                      onFocusChange: (bool hasFocus) {
                        if (!hasFocus) onEditFocusLost();
                      },
                      child: TextField(
                        controller: editController,
                        autofocus: true,
                        maxLines: null,
                        expands: false,
                        style: TextStyle(
                          fontFamily: ConsoleFont.mono,
                          fontSize: 12.5,
                          height: 1.6,
                          color: Console.text,
                        ),
                        decoration: const InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    )
                  : SingleChildScrollView(
                      child: Text(
                        text,
                        style: TextStyle(
                          fontFamily: ConsoleFont.mono,
                          fontSize: 12.5,
                          height: 1.6,
                          color: Console.textSoft,
                        ),
                      ),
                    ),
            ),
          ),
          if (notice != null) ...<Widget>[
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                Icon(Icons.auto_awesome, size: 15, color: Console.accent),
                const SizedBox(width: 7),
                Text(
                  notice!,
                  style: ConsoleText.chip.copyWith(color: Console.accent),
                ),
              ],
            ),
          ],
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              _PreviewAction(
                label: 'PASTE ⏎',
                onPressed: onPaste,
                primary: true,
              ),
              if (onConvert != null)
                _PreviewAction(
                  label: 'TO CAPTURE',
                  icon: Icons.auto_awesome,
                  onPressed: onConvert!,
                  color: Console.accent,
                ),
              // An image has no body to rewrite, and a control that does
              // nothing is worse than none.
              if (!isImage)
                _PreviewAction(
                  label: editing ? 'DONE' : 'EDIT',
                  icon: editing ? Icons.check_rounded : Icons.edit_outlined,
                  onPressed: editing ? onEndEdit : onEdit,
                  color: editing ? Console.accent : null,
                ),
              _PreviewAction(
                label: 'COLLECTIONS',
                icon: Icons.bookmark_border_rounded,
                onPressed: onCollections,
              ),
              _PreviewAction(
                label: 'DELETE',
                icon: Icons.delete_outline_rounded,
                onPressed: onDelete,
                color: Console.red,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One action in the preview's footer. Filled for the primary, outlined for the
/// rest — the same weight rule the queue card uses, so `DELETE` never reads as
/// the thing to press.
class _PreviewAction extends StatelessWidget {
  _PreviewAction({
    required this.label,
    required this.onPressed,
    this.icon,
    this.color,
    this.primary = false,
  });

  final String label;
  final VoidCallback onPressed;
  final IconData? icon;
  final Color? color;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final Color tint = color ?? Console.accent;
    return Semantics(
      button: true,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(9),
        child: Container(
          constraints: const BoxConstraints(minHeight: 38),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: primary ? Console.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: primary
                  ? Console.accent
                  : (color == null
                        ? Console.border
                        : tint.withValues(alpha: .45)),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (icon != null) ...<Widget>[
                Icon(
                  icon,
                  size: 15,
                  color: primary ? Console.ink : (color ?? Console.mutedSoft),
                ),
                const SizedBox(width: 7),
              ],
              Text(
                label,
                style: ConsoleText.chip.copyWith(
                  color: primary ? Console.ink : (color ?? Console.textSoft),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The one line that names an entry in the list and heads the preview. Taken
/// from the content because a clipboard entry has no title of its own; blank
/// and whitespace-only lines are skipped so a copied code block is named by its
/// first statement rather than by its indentation.
String _firstLine(ClipboardItem item) {
  if (item.type == ClipboardItemType.image) {
    return item.imagePath == null
        ? 'Image'
        : 'Image · ${item.imagePath!.split(Platform.pathSeparator).last}';
  }
  final String text = item.text ?? '';
  for (final String line in text.split('\n')) {
    if (line.trim().isNotEmpty) return line.trim();
  }
  return text.trim().isEmpty ? '(empty)' : text.trim();
}

/// `TEXT · 78 CHARS · 2 LINES`. Facts a preview can state precisely, in the
/// place the queue card states its verification footer.
String _metaLine(ClipboardItem item) {
  final String age = formatClipboardAge(item.copiedAt).toUpperCase();
  if (item.type == ClipboardItemType.image) {
    return 'IMAGE · $age';
  }
  final String text = item.text ?? '';
  final int lines = text.isEmpty ? 0 : text.split('\n').length;
  return 'TEXT · ${text.length} CHARS · $lines '
      '${lines == 1 ? 'LINE' : 'LINES'} · $age';
}
