import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Shared "Processing Console" palette and the small widgets every tab reuses.
/// Kept in one place so Queue, Models, Logs and Config stay visually identical.
class Console {
  const Console._();

  static const Color cyan = Color(0xFF31D5F4);
  static const Color background = Color(0xFF07111F);
  static const Color surface = Color(0xFF10243A);
  static const Color surfaceDeep = Color(0xFF0C1D2E);
  static const Color surfaceRaised = Color(0xFF112B42);
  static const Color border = Color(0xFF1B3852);
  static const Color muted = Color(0xFF6F8CA5);
  static const Color mutedSoft = Color(0xFF7894AA);
  static const Color text = Color(0xFFE6F1FA);
  static const Color textSoft = Color(0xFFC8D7E4);
  static const Color green = Color(0xFF4ADE80);
  static const Color amber = Color(0xFFFBBF24);
  static const Color red = Color(0xFFFF6B81);
  static const Color redSoft = Color(0xFFFF8FA1);
  static const Color ink = Color(0xFF00131A);
}

/// Copy-to-clipboard affordance, reusable by any tab that renders text worth
/// lifting out of the app.
///
/// Owns the short-lived "just copied" flag so the widgets embedding it can stay
/// stateless. Feedback is inline — the icon morphs into a check and settles
/// back — because the app deliberately uses no snackbars or dialogs anywhere.
class CopyButton extends StatefulWidget {
  const CopyButton({
    super.key,
    required this.text,
    this.tooltip = 'Copy text',
    this.semanticLabel = 'Copy text to clipboard',
  });

  /// Copied verbatim and in full, even when the caller renders it truncated.
  final String text;
  final String tooltip;
  final String semanticLabel;

  @override
  State<CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<CopyButton> {
  static const Duration _feedbackDuration = Duration(milliseconds: 1600);

  Timer? _resetTimer;
  bool _copied = false;

  @override
  void dispose() {
    // A card can leave the tree while the timer is still pending; without this
    // the callback would fire setState on a disposed element.
    _resetTimer?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (!mounted) return;
    setState(() => _copied = true);
    _resetTimer?.cancel();
    _resetTimer = Timer(_feedbackDuration, () {
      if (mounted) {
        setState(() => _copied = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: _copied ? 'Text copied to clipboard' : widget.semanticLabel,
      child: Tooltip(
        message: _copied ? 'Copied' : widget.tooltip,
        child: InkResponse(
          onTap: _copy,
          radius: 22,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 260),
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color:
                  _copied ? const Color(0xFF14402C) : const Color(0xFF102434),
              borderRadius: BorderRadius.circular(11),
              border: Border.all(
                color: _copied ? Console.green : Console.border,
              ),
            ),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 260),
              transitionBuilder: (Widget child, Animation<double> animation) {
                return ScaleTransition(
                  scale: CurvedAnimation(
                    parent: animation,
                    curve: Curves.easeOutBack,
                  ),
                  child: FadeTransition(opacity: animation, child: child),
                );
              },
              child: Icon(
                _copied ? Icons.check_rounded : Icons.copy_rounded,
                key: ValueKey<bool>(_copied),
                color: _copied ? Console.green : Console.muted,
                size: 17,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 8,
          fontWeight: FontWeight.w900,
          letterSpacing: .25,
        ),
      ),
    );
  }
}

class ErrorBanner extends StatelessWidget {
  const ErrorBanner({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(18, 4, 18, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF3A1823),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF6D2A3C)),
      ),
      child: Row(
        children: <Widget>[
          const Icon(Icons.error_outline, color: Console.redSoft),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message, style: const TextStyle(fontSize: 11)),
          ),
        ],
      ),
    );
  }
}

/// Uppercase section heading with an optional right-hand counter, e.g.
/// `PROVIDER PROFILES   3 ITEMS`.
class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.title, this.trailing});

  final String title;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: <Widget>[
        Text(
          title,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w800,
            letterSpacing: .2,
          ),
        ),
        if (trailing != null)
          Text(
            trailing!,
            style: const TextStyle(
              color: Console.muted,
              fontSize: 10,
              fontWeight: FontWeight.w800,
            ),
          ),
      ],
    );
  }
}

/// Bordered panel used for every non-list block (forms, info rows, warnings).
class ConsoleCard extends StatelessWidget {
  const ConsoleCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.accent,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: Console.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accent ?? Console.border),
      ),
      child: child,
    );
  }
}

class EmptyPanel extends StatelessWidget {
  const EmptyPanel({
    super.key,
    required this.icon,
    required this.title,
    required this.blurb,
  });

  final IconData icon;
  final String title;
  final String blurb;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 42),
      decoration: BoxDecoration(
        color: Console.surfaceDeep,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Console.border),
      ),
      child: Column(
        children: <Widget>[
          Icon(icon, size: 42, color: Console.cyan),
          const SizedBox(height: 13),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 7),
          Text(
            blurb,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Console.mutedSoft,
              fontSize: 11,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}

/// Key/value row for read-only facts (paths, counts, active model).
class InfoRow extends StatelessWidget {
  const InfoRow({
    super.key,
    required this.label,
    required this.value,
    this.valueColor,
    this.monospace = false,
  });

  final String label;
  final String value;
  final Color? valueColor;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: const TextStyle(
                color: Console.muted,
                fontSize: 9,
                fontWeight: FontWeight.w800,
                letterSpacing: .6,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: valueColor ?? Console.textSoft,
                fontSize: 11,
                height: 1.4,
                fontFamily: monospace ? 'monospace' : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String formatDuration(Duration duration) {
  final String minutes =
      duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final String seconds =
      duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

String formatDateTime(DateTime value) {
  final DateTime local = value.toLocal();
  return '${local.year}-${_two(local.month)}-${_two(local.day)} '
      '${_two(local.hour)}:${_two(local.minute)}';
}

String formatClock(DateTime value) {
  final DateTime local = value.toLocal();
  return '${_two(local.hour)}:${_two(local.minute)}:${_two(local.second)}';
}

String _two(int value) => value.toString().padLeft(2, '0');
