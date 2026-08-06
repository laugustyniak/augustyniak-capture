import 'dart:io';
import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../domain/clipboard_item.dart';
import '../domain/clipboard_watcher_service.dart';

class ClipboardHistorySheet extends StatefulWidget {
  const ClipboardHistorySheet({
    super.key,
    required this.watcherService,
  });

  final ClipboardWatcherService watcherService;

  @override
  State<ClipboardHistorySheet> createState() => _ClipboardHistorySheetState();
}

class _ClipboardHistorySheetState extends State<ClipboardHistorySheet> {
  final TextEditingController _searchController = TextEditingController();
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() {
        _filter = _searchController.text.trim().toLowerCase();
      });
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  String _formatTime(DateTime dateTime) {
    final DateTime now = DateTime.now();
    final Duration diff = now.difference(dateTime);
    if (diff.inSeconds < 60) return 'Przed chwilą';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min temu';
    if (diff.inHours < 24) return '${diff.inHours}h temu';
    return '${dateTime.day}.${dateTime.month.toString().padLeft(2, '0')} ${dateTime.hour}:${dateTime.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.watcherService,
      builder: (BuildContext context, Widget? child) {
        final List<ClipboardItem> allItems = widget.watcherService.items;
        final List<ClipboardItem> items = _filter.isEmpty
            ? allItems
            : allItems.where((item) {
                final String text = (item.text ?? '').toLowerCase();
                return text.contains(_filter);
              }).toList();

        return Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.85,
          ),
          decoration: BoxDecoration(
            color: Console.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
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
                      Icon(Icons.content_paste_rounded, color: Console.accent, size: 22),
                      const SizedBox(width: 10),
                      Text(
                        'SCHOWEK SYSTEMOWY',
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
                          icon: Icon(Icons.delete_sweep_outlined, size: 18, color: Console.red),
                          label: Text(
                            'Wyczyszcz',
                            style: TextStyle(color: Console.red, fontSize: 13),
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
                    autofocus: false,
                    style: TextStyle(color: Console.text, fontSize: 14),
                    decoration: InputDecoration(
                      hintText: 'Szukaj w schowku...',
                      hintStyle: TextStyle(color: Console.dimText, fontSize: 14),
                      prefixIcon: Icon(Icons.search, color: Console.dimText, size: 20),
                      suffixIcon: _filter.isNotEmpty
                          ? IconButton(
                              icon: Icon(Icons.clear, color: Console.dimText, size: 18),
                              onPressed: () => _searchController.clear(),
                            )
                          : null,
                      filled: true,
                      fillColor: Console.surfaceRaised,
                      contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
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
                const SizedBox(height: 12),
                Divider(height: 1, color: Console.border),
                Expanded(
                  child: items.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: <Widget>[
                              Icon(Icons.assignment_outlined, size: 48, color: Console.dim),
                              const SizedBox(height: 12),
                              Text(
                                _filter.isEmpty
                                    ? 'Schowek jest pusty'
                                    : 'Brak wyników wyszukiwania',
                                style: TextStyle(color: Console.muted, fontSize: 15),
                              ),
                            ],
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                          itemCount: items.length,
                          separatorBuilder: (BuildContext context, int index) => const SizedBox(height: 6),
                          itemBuilder: (BuildContext context, int index) {
                            final ClipboardItem item = items[index];
                            return _ClipboardItemTile(
                              item: item,
                              timeLabel: _formatTime(item.copiedAt),
                              onTap: () async {
                                await widget.watcherService.copyToClipboard(item);
                                if (context.mounted) {
                                  Navigator.of(context).pop();
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Row(
                                        children: <Widget>[
                                          Icon(Icons.check_circle_outline, color: Console.green, size: 20),
                                          const SizedBox(width: 10),
                                          const Text('Skopiowano do schowka'),
                                        ],
                                      ),
                                      duration: const Duration(seconds: 2),
                                      backgroundColor: Console.surface,
                                      behavior: SnackBarBehavior.floating,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(8),
                                        side: BorderSide(color: Console.border),
                                      ),
                                    ),
                                  );
                                }
                              },
                              onDelete: () async {
                                await widget.watcherService.deleteItem(item.id);
                              },
                            );
                          },
                        ),
                ),
              ],
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
    required this.onTap,
    required this.onDelete,
  });

  final ClipboardItem item;
  final String timeLabel;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final bool isImage = item.type == ClipboardItemType.image;
    final String previewText = item.text ?? '';

    return Material(
      color: Console.surfaceRaised,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
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
                  color: isImage ? Console.pink.withValues(alpha: .15) : Console.accent.withValues(alpha: .15),
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
                            color: Console.dimText,
                          ),
                        ),
                        const Spacer(),
                        InkWell(
                          onTap: onDelete,
                          borderRadius: BorderRadius.circular(4),
                          child: Padding(
                            padding: const EdgeInsets.all(4.0),
                            child: Icon(Icons.close, size: 16, color: Console.dimText),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    if (isImage && item.imagePath != null) ...<Widget>[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: Image.file(
                          File(item.imagePath!),
                          height: 80,
                          fit: BoxFit.cover,
                          errorBuilder: (BuildContext context, Object error, StackTrace? stackTrace) => Text(
                            '[Obraz nieodczytany]',
                            style: TextStyle(color: Console.red, fontSize: 13),
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
    );
  }
}
