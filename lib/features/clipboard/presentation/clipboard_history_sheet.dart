import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/ui_kit.dart';
import '../../recordings/domain/capture_type.dart';
import '../../recordings/presentation/recordings_controller.dart';
import '../domain/clipboard_item.dart';
import '../domain/clipboard_watcher_service.dart';

/// Seed vocabulary for clipboard collections, offered both as naming
/// suggestions in the "add to collection" sheet and as filter chips.
///
/// One definition on purpose: these were two literal lists that had already
/// drifted apart — the chip list was missing `Important`. Same rule as
/// `_matches()` in `queue_tab.dart`, where one definition serves both the
/// filter and its counts so the two cannot disagree.
///
/// Translating these does not rename anything already saved. A user with items
/// tagged `Ulubione` sees both a `Favorites` chip (this default, empty) and an
/// `Ulubione` chip (their data), because the chip list is these defaults
/// unioned with the collections actually in use.
const List<String> kDefaultClipboardCollections = <String>[
  'Favorites',
  'Code',
  'Prompts',
  'Important',
];

class ClipboardHistorySheet extends StatefulWidget {
  const ClipboardHistorySheet({
    super.key,
    required this.watcherService,
    this.recordingsController,
    this.onConvertText,
    this.onConvertImage,
  });

  final ClipboardWatcherService watcherService;
  final RecordingsController? recordingsController;
  final Future<void> Function(String text)? onConvertText;
  final Future<void> Function(File image)? onConvertImage;

  @override
  State<ClipboardHistorySheet> createState() => _ClipboardHistorySheetState();
}

class _ClipboardHistorySheetState extends State<ClipboardHistorySheet> {
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _searchFocusNode = FocusNode();
  String _filter = '';
  String? _selectedCollection; // null = All
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
  }

  void _onSearchChanged() {
    setState(() {
      _filter = _searchController.text.trim().toLowerCase();
      _selectedIndex = 0;
    });
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _scrollController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  String _formatTime(DateTime dateTime) {
    final DateTime now = DateTime.now();
    final Duration diff = now.difference(dateTime);
    if (diff.inSeconds < 60) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${dateTime.day}.${dateTime.month.toString().padLeft(2, '0')} ${dateTime.hour}:${dateTime.minute.toString().padLeft(2, '0')}';
  }

  void _selectAndCopy(BuildContext context, ClipboardItem item) async {
    await widget.watcherService.copyToClipboard(item);
    if (context.mounted) {
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      await widget.watcherService.pasteToActiveApp();
    }
  }

  void _convertToCapture(BuildContext context, ClipboardItem item) async {
    final bool canConvertText =
        widget.onConvertText != null || widget.recordingsController != null;
    final bool canConvertImage =
        widget.onConvertImage != null || widget.recordingsController != null;

    if (item.type == ClipboardItemType.image && item.imagePath != null) {
      if (!canConvertImage) return;
      final File imageFile = File(item.imagePath!);
      if (await imageFile.exists()) {
        if (widget.onConvertImage != null) {
          await widget.onConvertImage!(imageFile);
        } else {
          await widget.recordingsController!.addImportedFile(
            imageFile,
            CaptureType.image,
          );
        }
        if (context.mounted) {
          Navigator.of(context).pop();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: <Widget>[
                  Icon(Icons.auto_awesome, color: Console.accent, size: 20),
                  const SizedBox(width: 10),
                  const Text('Image sent for Vision LLM / OCR analysis ✨'),
                ],
              ),
              duration: const Duration(seconds: 2),
              backgroundColor: Console.surface,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: BorderSide(color: Console.accent),
              ),
            ),
          );
        }
      }
    } else if (item.text != null && item.text!.trim().isNotEmpty) {
      if (!canConvertText) return;
      if (widget.onConvertText != null) {
        await widget.onConvertText!(item.text!);
      } else {
        await widget.recordingsController!.addTextNote(item.text!);
      }
      if (context.mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: <Widget>[
                Icon(Icons.auto_awesome, color: Console.accent, size: 20),
                const SizedBox(width: 10),
                const Text('Sent to LLM processing (Capture ✨)'),
              ],
            ),
            duration: const Duration(seconds: 2),
            backgroundColor: Console.surface,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(color: Console.accent),
            ),
          ),
        );
      }
    }
  }

  void _scrollToSelected(int index) {
    if (!_scrollController.hasClients) return;
    const double itemHeight = 72.0;
    final double targetOffset = (index * itemHeight).clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );
    _scrollController.jumpTo(targetOffset);
  }

  void _handleKeyEvent(KeyEvent event, List<ClipboardItem> items) {
    if (event is! KeyDownEvent) return;

    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      if (items.isNotEmpty) {
        setState(() {
          _selectedIndex = (_selectedIndex + 1).clamp(0, items.length - 1);
        });
        _scrollToSelected(_selectedIndex);
      }
    } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      if (items.isNotEmpty) {
        setState(() {
          _selectedIndex = (_selectedIndex - 1).clamp(0, items.length - 1);
        });
        _scrollToSelected(_selectedIndex);
      }
    } else if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      if (items.isNotEmpty &&
          _selectedIndex >= 0 &&
          _selectedIndex < items.length) {
        _selectAndCopy(context, items[_selectedIndex]);
      }
    }
  }

  Future<void> _promptNewCollection(BuildContext context) async {
    final TextEditingController nameController = TextEditingController();
    final String? collectionName = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => ConsolePaletteScope(
        builder: (BuildContext context) => AlertDialog(
          backgroundColor: Console.surface,
          title: Text(
            'NEW COLLECTION',
            style: TextStyle(
              fontFamily: ConsoleFont.display,
              fontSize: 16,
              color: Console.text,
            ),
          ),
          content: TextField(
            controller: nameController,
            autofocus: true,
            style: TextStyle(color: Console.text),
            decoration: InputDecoration(
              hintText: 'Collection name (e.g. Prompts, Code)...',
              hintStyle: TextStyle(color: Console.dimText),
              filled: true,
              fillColor: Console.surfaceRaised,
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('Cancel', style: TextStyle(color: Console.dimText)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Console.accent),
              onPressed: () {
                final String text = nameController.text.trim();
                if (text.isNotEmpty) {
                  Navigator.of(context).pop(text);
                }
              },
              child: Text('Add', style: TextStyle(color: Console.ink)),
            ),
          ],
        ),
      ),
    );

    if (collectionName != null && collectionName.isNotEmpty) {
      setState(() {
        _selectedCollection = collectionName;
      });
    }
  }

  Future<void> _manageItemCollections(
    BuildContext context,
    ClipboardItem item,
  ) async {
    final Set<String> existingCollections =
        widget.watcherService.allCollections;
    final Set<String> defaultSuggestions = <String>{
      ...kDefaultClipboardCollections,
      ...existingCollections,
    };

    await showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext context) => ConsolePaletteScope(
        builder: (BuildContext context) => ListenableBuilder(
          listenable: widget.watcherService,
          builder: (BuildContext context, Widget? child) {
            final ClipboardItem liveItem = widget.watcherService.items
                .firstWhere((e) => e.id == item.id, orElse: () => item);

            return Container(
              padding: const EdgeInsets.all(20),
              color: Console.surface,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'ADD TO COLLECTION',
                    style: TextStyle(
                      fontFamily: ConsoleFont.display,
                      fontSize: 15,
                      color: Console.text,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      for (final String collection in defaultSuggestions)
                        FilterChip(
                          selected: liveItem.collections.contains(collection),
                          label: Text(collection),
                          labelStyle: TextStyle(
                            color: liveItem.collections.contains(collection)
                                ? Console.accent
                                : Console.text,
                            fontSize: 13,
                          ),
                          selectedColor: Console.accent.withValues(alpha: .2),
                          backgroundColor: Console.surfaceRaised,
                          onSelected: (_) async {
                            await widget.watcherService.toggleItemCollection(
                              liveItem.id,
                              collection,
                            );
                          },
                        ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.watcherService,
      builder: (BuildContext context, Widget? child) {
        final List<ClipboardItem> allItems = widget.watcherService.items;
        final Set<String> collections = <String>{
          ...kDefaultClipboardCollections,
          ...widget.watcherService.allCollections,
        };

        final List<ClipboardItem> filteredItems = allItems.where((item) {
          // Filter by collection
          if (_selectedCollection != null &&
              !item.collections.contains(_selectedCollection)) {
            return false;
          }
          // Filter by search text
          if (_filter.isNotEmpty) {
            final String text = (item.text ?? '').toLowerCase();
            if (!text.contains(_filter)) return false;
          }
          return true;
        }).toList();

        // Ensure selection index stays valid
        if (filteredItems.isEmpty) {
          _selectedIndex = 0;
        } else if (_selectedIndex >= filteredItems.length) {
          _selectedIndex = filteredItems.length - 1;
        }

        return KeyboardListener(
          focusNode: _searchFocusNode,
          onKeyEvent: (KeyEvent event) => _handleKeyEvent(event, filteredItems),
          child: Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.88,
            ),
            decoration: BoxDecoration(
              color: Console.surface,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(20),
              ),
              border: Border(
                top: BorderSide(color: Console.borderStrong),
                left: BorderSide(color: Console.borderStrong),
                right: BorderSide(color: Console.borderStrong),
              ),
            ),
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const SizedBox(height: 12),
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Console.borderStrong,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Row(
                      children: <Widget>[
                        Icon(
                          Icons.content_paste_rounded,
                          color: Console.accent,
                          size: 22,
                        ),
                        const SizedBox(width: 10),
                        Text(
                          'SYSTEM CLIPBOARD',
                          style: TextStyle(
                            fontFamily: ConsoleFont.display,
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            letterSpacing: 1.1,
                            color: Console.text,
                          ),
                        ),
                        const Spacer(),
                        if (allItems.isNotEmpty)
                          TextButton.icon(
                            onPressed: () async {
                              await widget.watcherService.clearHistory();
                            },
                            icon: Icon(
                              Icons.delete_sweep_outlined,
                              size: 18,
                              color: Console.red,
                            ),
                            label: Text(
                              'Clear',
                              style: TextStyle(
                                color: Console.red,
                                fontSize: 13,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: TextField(
                      controller: _searchController,
                      autofocus: true,
                      style: TextStyle(color: Console.text, fontSize: 14),
                      decoration: InputDecoration(
                        hintText: 'Type to search... (use ↑ ↓ and Enter)',
                        hintStyle: TextStyle(
                          color: Console.dimText,
                          fontSize: 13,
                        ),
                        prefixIcon: Icon(
                          Icons.search,
                          color: Console.dimText,
                          size: 20,
                        ),
                        suffixIcon: _filter.isNotEmpty
                            ? IconButton(
                                icon: Icon(
                                  Icons.clear,
                                  color: Console.dimText,
                                  size: 18,
                                ),
                                onPressed: () => _searchController.clear(),
                              )
                            : null,
                        filled: true,
                        fillColor: Console.surfaceRaised,
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 10,
                          horizontal: 14,
                        ),
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
                    ),
                  ),
                  const SizedBox(height: 10),
                  // Collections strip
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Row(
                      children: <Widget>[
                        ChoiceChip(
                          label: const Text('All'),
                          selected: _selectedCollection == null,
                          selectedColor: Console.accent.withValues(alpha: .25),
                          backgroundColor: Console.surfaceRaised,
                          labelStyle: TextStyle(
                            color: _selectedCollection == null
                                ? Console.accent
                                : Console.muted,
                            fontWeight: _selectedCollection == null
                                ? FontWeight.bold
                                : FontWeight.normal,
                            fontSize: 12,
                          ),
                          onSelected: (_) =>
                              setState(() => _selectedCollection = null),
                        ),
                        const SizedBox(width: 6),
                        for (final String colName in collections) ...<Widget>[
                          ChoiceChip(
                            label: Text(colName),
                            selected: _selectedCollection == colName,
                            selectedColor: Console.accent.withValues(
                              alpha: .25,
                            ),
                            backgroundColor: Console.surfaceRaised,
                            labelStyle: TextStyle(
                              color: _selectedCollection == colName
                                  ? Console.accent
                                  : Console.muted,
                              fontWeight: _selectedCollection == colName
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                              fontSize: 12,
                            ),
                            onSelected: (_) =>
                                setState(() => _selectedCollection = colName),
                          ),
                          const SizedBox(width: 6),
                        ],
                        ActionChip(
                          avatar: Icon(
                            Icons.add,
                            size: 16,
                            color: Console.accent,
                          ),
                          label: const Text('New'),
                          backgroundColor: Console.surfaceRaised,
                          labelStyle: TextStyle(
                            color: Console.accent,
                            fontSize: 12,
                          ),
                          onPressed: () => _promptNewCollection(context),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  Divider(height: 1, color: Console.border),
                  Expanded(
                    child: filteredItems.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: <Widget>[
                                Icon(
                                  Icons.assignment_outlined,
                                  size: 48,
                                  color: Console.dim,
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  _filter.isEmpty && _selectedCollection == null
                                      ? 'Clipboard is empty'
                                      : 'No results in this collection / search',
                                  style: TextStyle(
                                    color: Console.muted,
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            ),
                          )
                        : ListView.separated(
                            controller: _scrollController,
                            padding: const EdgeInsets.symmetric(
                              vertical: 8,
                              horizontal: 16,
                            ),
                            itemCount: filteredItems.length,
                            separatorBuilder:
                                (BuildContext context, int index) =>
                                    const SizedBox(height: 6),
                            itemBuilder: (BuildContext context, int index) {
                              final ClipboardItem item = filteredItems[index];
                              final bool isSelected = index == _selectedIndex;
                              return _ClipboardItemTile(
                                item: item,
                                timeLabel: _formatTime(item.copiedAt),
                                isSelected: isSelected,
                                onTap: () => _selectAndCopy(context, item),
                                onConvertToCapture:
                                    (widget.recordingsController != null ||
                                            widget.onConvertText != null ||
                                            widget.onConvertImage != null) &&
                                        (item.text != null ||
                                            item.imagePath != null)
                                    ? () => _convertToCapture(context, item)
                                    : null,
                                onAddCollection: () =>
                                    _manageItemCollections(context, item),
                                onDelete: () async {
                                  await widget.watcherService.deleteItem(
                                    item.id,
                                  );
                                },
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
}

class _ClipboardItemTile extends StatelessWidget {
  const _ClipboardItemTile({
    required this.item,
    required this.timeLabel,
    required this.isSelected,
    required this.onTap,
    this.onConvertToCapture,
    required this.onAddCollection,
    required this.onDelete,
  });

  final ClipboardItem item;
  final String timeLabel;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback? onConvertToCapture;
  final VoidCallback onAddCollection;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final bool isImage = item.type == ClipboardItemType.image;
    final String previewText = item.text ?? '';

    return Material(
      color: isSelected
          ? Console.accent.withValues(alpha: .18)
          : Console.surfaceRaised,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? Console.accent : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Container(
                  margin: const EdgeInsets.only(top: 2),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: isImage
                        ? Console.pink.withValues(alpha: .15)
                        : Console.accent.withValues(alpha: .15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    isImage ? Icons.image_rounded : Icons.short_text_rounded,
                    color: isImage ? Console.pink : Console.accent,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Text(
                            timeLabel,
                            style: TextStyle(
                              fontFamily: ConsoleFont.mono,
                              fontSize: 11,
                              color: isSelected
                                  ? Console.accent
                                  : Console.dimText,
                              fontWeight: isSelected
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                          const SizedBox(width: 8),
                          for (final String col
                              in item.collections) ...<Widget>[
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: Console.accent.withValues(alpha: .15),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                col,
                                style: TextStyle(
                                  color: Console.accent,
                                  fontSize: 10,
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                          ],
                          const Spacer(),
                          if (onConvertToCapture != null) ...<Widget>[
                            InkWell(
                              onTap: onConvertToCapture,
                              borderRadius: BorderRadius.circular(4),
                              child: Padding(
                                padding: const EdgeInsets.all(4.0),
                                child: Tooltip(
                                  message: 'Send to LLM processing (Capture ✨)',
                                  child: Icon(
                                    Icons.auto_awesome,
                                    size: 16,
                                    color: Console.accent,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                          ],
                          InkWell(
                            onTap: onAddCollection,
                            borderRadius: BorderRadius.circular(4),
                            child: Padding(
                              padding: const EdgeInsets.all(4.0),
                              child: Icon(
                                Icons.bookmark_border_rounded,
                                size: 16,
                                color: Console.muted,
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          InkWell(
                            onTap: onDelete,
                            borderRadius: BorderRadius.circular(4),
                            child: Padding(
                              padding: const EdgeInsets.all(4.0),
                              child: Icon(
                                Icons.close,
                                size: 16,
                                color: Console.dimText,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      if (isImage && item.imagePath != null) ...<Widget>[
                        const SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            constraints: const BoxConstraints(maxHeight: 120),
                            decoration: BoxDecoration(
                              border: Border.all(color: Console.border),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Image.file(
                              File(item.imagePath!),
                              height: 110,
                              fit: BoxFit.cover,
                              alignment: Alignment.centerLeft,
                              errorBuilder:
                                  (
                                    BuildContext context,
                                    Object error,
                                    StackTrace? stackTrace,
                                  ) => Padding(
                                    padding: const EdgeInsets.all(8.0),
                                    child: Text(
                                      '[Could not load image]',
                                      style: TextStyle(
                                        color: Console.red,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                            ),
                          ),
                        ),
                      ] else ...<Widget>[
                        Text(
                          previewText,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: ConsoleFont.mono,
                            fontSize: 13,
                            color: Console.text,
                            fontWeight: isSelected
                                ? FontWeight.w500
                                : FontWeight.normal,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
