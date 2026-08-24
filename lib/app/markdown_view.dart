import 'package:flutter/material.dart';

import 'markdown/simple_markdown.dart';

/// Draws capture text that happens to be markdown.
///
/// The parser is pure Dart in `markdown/simple_markdown.dart`; this widget is
/// only the type scale and the furniture. Two rules govern it:
///
/// * **`Text.rich`, never `SelectableText`.** The caller wraps the whole body
///   in a `SelectionArea`, and a `SelectableText` inside one throws. Selection
///   therefore comes from above, and it covers links as well.
/// * **No `const` constructor** — not on this widget and not on its private
///   children. `Console`'s colours are getters over mutable global state, so
///   Flutter's "identical child, skip the rebuild" shortcut would keep painting
///   the previous theme after a swap. Colours arrive here as parameters, and
///   the same rule applies for the same reason.
///
/// Links are rendered — accent colour, underlined — and deliberately **not**
/// tappable: the app carries no `url_launcher`, and opening a URL out of a
/// model-written string is a decision that belongs somewhere it can be
/// reviewed. The text is selectable, so a reader can still copy it.
class SimpleMarkdown extends StatelessWidget {
  SimpleMarkdown({
    super.key,
    required this.text,
    required this.baseStyle,
    this.codeStyle,
    this.accentColor,
    this.mutedColor,
    this.borderColor,
    this.blockSpacing = 10,
  });

  /// The raw capture text — a transcript, an OCR result or a typed note.
  final String text;

  /// Body type. Headings, quotes and code all scale off this.
  final TextStyle baseStyle;

  /// Monospace type for code spans and fenced blocks. Falls back to
  /// [baseStyle] in JetBrains Mono.
  final TextStyle? codeStyle;

  /// Link colour, and the bullet/number tint.
  final Color? accentColor;

  /// The quote rule and the list markers.
  final Color? mutedColor;

  /// The border of a fenced code block.
  final Color? borderColor;

  /// Vertical gap between blocks.
  final double blockSpacing;

  @override
  Widget build(BuildContext context) {
    final List<MarkdownBlock> blocks = parseSimpleMarkdown(text);
    if (blocks.isEmpty) {
      return const SizedBox.shrink();
    }

    final TextStyle code =
        codeStyle ??
        baseStyle.copyWith(
          fontFamily: 'JetBrainsMono',
          fontFamilyFallback: const <String>['monospace'],
        );
    // Never a literal hex — every raw colour in this app belongs in
    // `ConsolePalette`, and the theme in force is a fallback that cannot be
    // wrong the way an invented grey can.
    final Color marker =
        mutedColor ?? baseStyle.color ?? Theme.of(context).dividerColor;

    final List<Widget> children = <Widget>[];
    for (int i = 0; i < blocks.length; i++) {
      if (i > 0) {
        children.add(SizedBox(height: blockSpacing));
      }
      children.add(_block(blocks[i], code, marker));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  Widget _block(MarkdownBlock block, TextStyle code, Color marker) {
    switch (block) {
      case MarkdownHeading(level: final int level, spans: final List<MarkdownSpan> spans):
        return Text.rich(
          _inline(spans, _headingStyle(level), code),
          textAlign: TextAlign.start,
        );

      case MarkdownParagraph(spans: final List<MarkdownSpan> spans):
        return Text.rich(_inline(spans, baseStyle, code));

      case MarkdownBullet(spans: final List<MarkdownSpan> spans, depth: final int depth):
        return Padding(
          padding: EdgeInsets.only(left: 12.0 * depth),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(
                width: 16,
                child: Text(
                  depth == 0 ? '•' : '◦',
                  style: baseStyle.copyWith(color: marker),
                ),
              ),
              Expanded(child: Text.rich(_inline(spans, baseStyle, code))),
            ],
          ),
        );

      case MarkdownNumbered(
        spans: final List<MarkdownSpan> spans,
        number: final int number,
        depth: final int depth,
      ):
        return Padding(
          padding: EdgeInsets.only(left: 12.0 * depth),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(
                width: 22,
                child: Text(
                  '$number.',
                  textAlign: TextAlign.right,
                  style: (codeStyle ?? baseStyle).copyWith(color: marker),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(child: Text.rich(_inline(spans, baseStyle, code))),
            ],
          ),
        );

      case MarkdownQuote(spans: final List<MarkdownSpan> spans):
        return Container(
          padding: const EdgeInsets.only(left: 10),
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: marker, width: 2)),
          ),
          child: Text.rich(
            _inline(
              spans,
              baseStyle.copyWith(fontStyle: FontStyle.italic),
              code,
            ),
          ),
        );

      case MarkdownCode(text: final String body, language: final String? language):
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: borderColor ?? marker),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (language != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    language.toUpperCase(),
                    style: code.copyWith(
                      fontSize: (code.fontSize ?? 13) * 0.8,
                      letterSpacing: 1.2,
                      color: marker,
                    ),
                  ),
                ),
              Text(body, style: code),
            ],
          ),
        );

      case MarkdownRule():
        return Container(height: 1, color: borderColor ?? marker);
    }
  }

  TextStyle _headingStyle(int level) {
    final double size = baseStyle.fontSize ?? 14;
    return switch (level) {
      1 => baseStyle.copyWith(
        fontSize: size * 1.5,
        fontWeight: FontWeight.w700,
        height: 1.2,
      ),
      2 => baseStyle.copyWith(
        fontSize: size * 1.3,
        fontWeight: FontWeight.w700,
        height: 1.25,
      ),
      _ => baseStyle.copyWith(
        fontSize: size * 1.15,
        fontWeight: FontWeight.w600,
        height: 1.3,
      ),
    };
  }

  /// One block's spans as a single `TextSpan` tree.
  InlineSpan _inline(
    List<MarkdownSpan> spans,
    TextStyle blockStyle,
    TextStyle code,
  ) {
    return TextSpan(
      style: blockStyle,
      children: spans.map((MarkdownSpan span) {
        TextStyle style = span.code
            ? code.copyWith(
                fontSize: (blockStyle.fontSize ?? 14) * 0.94,
                color: code.color ?? blockStyle.color,
              )
            : blockStyle;
        if (span.bold) {
          style = style.copyWith(fontWeight: FontWeight.w700);
        }
        if (span.italic) {
          style = style.copyWith(fontStyle: FontStyle.italic);
        }
        if (span.href != null) {
          style = style.copyWith(
            color: accentColor ?? style.color,
            decoration: TextDecoration.underline,
            decorationColor: accentColor ?? style.color,
          );
        }
        return TextSpan(text: span.text, style: style);
      }).toList(growable: false),
    );
  }
}
