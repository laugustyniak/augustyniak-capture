/// A very small markdown reader for capture text.
///
/// It exists because the app vendors everything it needs — it is offline-first
/// and `flutter_markdown` is discontinued — and because the text it renders is
/// *dictated prose*, not authored markdown. That second fact is what shapes
/// the whole parser: a transcript is full of stray asterisks ("5 * 3 = 15"),
/// underscores (`snake_case_name`) and brackets, and a reader that swallows
/// them silently corrupts the note. So **an unmatched marker always stays
/// literal**, a marker flanked by whitespace never opens emphasis, and a
/// marker inside a word never opens it either. Losing a little formatting is
/// recoverable; eating the user's characters is not.
///
/// Deliberately pure Dart: no `package:flutter` import, so the whole thing is
/// testable with no binding. The widget that draws these blocks lives in
/// `lib/app/markdown_view.dart`.
///
/// The work is bounded. Blocks are one linear pass over the lines; inline
/// scanning searches at most [_maxDelimiterSpan] characters ahead for a
/// closing marker and nests at most [_maxNestingDepth] deep, so a transcript
/// of tens of thousands of characters — including one that is nothing but
/// stray markers — costs a constant multiple of its length rather than its
/// square. Emphasis genuinely spanning more than 2 kB is not parsed, which is
/// the right side of that trade for this input.
library;

/// How far ahead a marker will look for its partner.
const int _maxDelimiterSpan = 2048;

/// How deeply emphasis and links may nest before further markers are read as
/// literal text.
const int _maxNestingDepth = 8;

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

/// One run of inline text and everything that is true of it.
///
/// Value equality is deliberate: it is what lets a test compare a parse
/// against a literal list instead of walking it by hand.
class MarkdownSpan {
  const MarkdownSpan(
    this.text, {
    this.bold = false,
    this.italic = false,
    this.code = false,
    this.href,
  });

  final String text;
  final bool bold;
  final bool italic;
  final bool code;

  /// The link target, or null when this run is not part of a link. The parser
  /// never opens it — see the widget for why links are drawn, not tapped.
  final String? href;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MarkdownSpan &&
          other.text == text &&
          other.bold == bold &&
          other.italic == italic &&
          other.code == code &&
          other.href == href;

  @override
  int get hashCode => Object.hash(text, bold, italic, code, href);

  @override
  String toString() {
    final List<String> flags = <String>[
      if (bold) 'bold',
      if (italic) 'italic',
      if (code) 'code',
      if (href != null) 'href=$href',
    ];
    return 'MarkdownSpan(${_quote(text)}${flags.isEmpty ? '' : ', ${flags.join(', ')}'})';
  }

  static String _quote(String value) => "'${value.replaceAll('\n', r'\n')}'";
}

/// One block of a parsed document.
sealed class MarkdownBlock {
  const MarkdownBlock();
}

/// `#`..`######`. Levels above three are clamped to three — the app has no
/// type scale below that, and a deeper heading should still read as a heading.
class MarkdownHeading extends MarkdownBlock {
  const MarkdownHeading(this.level, this.spans);

  final int level;
  final List<MarkdownSpan> spans;
}

/// Blank-line separated prose. Wrapped lines keep their newline: dictated text
/// has meaningful line breaks, so they are soft breaks rather than noise.
class MarkdownParagraph extends MarkdownBlock {
  const MarkdownParagraph(this.spans);

  final List<MarkdownSpan> spans;
}

/// A `-`/`*`/`+` item. [depth] counts two-space (or one tab) indents.
class MarkdownBullet extends MarkdownBlock {
  const MarkdownBullet(this.spans, this.depth);

  final List<MarkdownSpan> spans;
  final int depth;
}

/// A `1.` item. [number] is the one the author wrote, not a running count —
/// a list that starts at 7 renders starting at 7.
class MarkdownNumbered extends MarkdownBlock {
  const MarkdownNumbered(this.spans, this.number, this.depth);

  final List<MarkdownSpan> spans;
  final int number;
  final int depth;
}

/// Consecutive `>` lines, merged into one block with soft breaks between them.
class MarkdownQuote extends MarkdownBlock {
  const MarkdownQuote(this.spans);

  final List<MarkdownSpan> spans;
}

/// A fenced block. Its text is verbatim — no inline parsing happens inside it.
class MarkdownCode extends MarkdownBlock {
  const MarkdownCode(this.text, {this.language});

  final String text;
  final String? language;
}

/// `---`, `***` or `___` alone on a line.
class MarkdownRule extends MarkdownBlock {
  const MarkdownRule();
}

// ---------------------------------------------------------------------------
// Block parsing
// ---------------------------------------------------------------------------

/// Reads [source] into blocks. Never throws; every unrecognised construct
/// degrades to literal text.
List<MarkdownBlock> parseSimpleMarkdown(String source) {
  final List<MarkdownBlock> blocks = <MarkdownBlock>[];
  if (source.isEmpty) {
    return blocks;
  }

  final List<String> lines = _normalize(source).split('\n');
  final List<String> paragraph = <String>[];

  void flushParagraph() {
    if (paragraph.isEmpty) {
      return;
    }
    blocks.add(MarkdownParagraph(parseInlineMarkdown(paragraph.join('\n'))));
    paragraph.clear();
  }

  int i = 0;
  while (i < lines.length) {
    final String line = lines[i];

    if (line.trim().isEmpty) {
      flushParagraph();
      i++;
      continue;
    }

    final _Fence? fence = _openingFence(line);
    if (fence != null) {
      flushParagraph();
      final List<String> body = <String>[];
      int j = i + 1;
      bool closed = false;
      while (j < lines.length) {
        if (_closesFence(lines[j], fence)) {
          closed = true;
          j++;
          break;
        }
        body.add(lines[j]);
        j++;
      }
      if (!closed) {
        // An unterminated fence runs to the end of the input; the input's own
        // trailing blank lines are not lines of code.
        while (body.isNotEmpty && body.last.trim().isEmpty) {
          body.removeLast();
        }
      }
      blocks.add(MarkdownCode(body.join('\n'), language: fence.language));
      i = j;
      continue;
    }

    if (_isRule(line)) {
      flushParagraph();
      blocks.add(const MarkdownRule());
      i++;
      continue;
    }

    final MarkdownHeading? heading = _heading(line);
    if (heading != null) {
      flushParagraph();
      blocks.add(heading);
      i++;
      continue;
    }

    if (_quoteContent(line) != null) {
      flushParagraph();
      final List<String> quoted = <String>[];
      while (i < lines.length) {
        final String? content = _quoteContent(lines[i]);
        if (content == null) {
          break;
        }
        quoted.add(content);
        i++;
      }
      blocks.add(MarkdownQuote(parseInlineMarkdown(quoted.join('\n'))));
      continue;
    }

    final MarkdownBlock? item = _listItem(line);
    if (item != null) {
      flushParagraph();
      blocks.add(item);
      i++;
      continue;
    }

    paragraph.add(line.trim());
    i++;
  }

  flushParagraph();
  return blocks;
}

/// CRLF and lone CR both mean "new line" here — a capture can arrive from any
/// platform's clipboard. Trailing newlines carry nothing and are dropped so an
/// unterminated fence does not end with a phantom blank line.
String _normalize(String source) {
  String text = source.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  while (text.endsWith('\n')) {
    text = text.substring(0, text.length - 1);
  }
  return text;
}

class _Fence {
  const _Fence(this.char, this.length, this.language);

  final int char;
  final int length;
  final String? language;
}

_Fence? _openingFence(String line) {
  final String trimmed = line.trimLeft();
  if (trimmed.length < 3) {
    return null;
  }
  final int char = trimmed.codeUnitAt(0);
  if (char != 0x60 && char != 0x7E) {
    return null;
  }
  int run = 1;
  while (run < trimmed.length && trimmed.codeUnitAt(run) == char) {
    run++;
  }
  if (run < 3) {
    return null;
  }
  final String info = trimmed.substring(run).trim();
  // A backtick inside the info string is not an opening fence in CommonMark,
  // and here it is almost always prose.
  if (char == 0x60 && info.contains('`')) {
    return null;
  }
  return _Fence(char, run, info.isEmpty ? null : info);
}

bool _closesFence(String line, _Fence fence) {
  final String trimmed = line.trim();
  if (trimmed.length < fence.length) {
    return false;
  }
  for (int i = 0; i < trimmed.length; i++) {
    if (trimmed.codeUnitAt(i) != fence.char) {
      return false;
    }
  }
  return true;
}

bool _isRule(String line) {
  final String stripped = line.replaceAll(' ', '').replaceAll('\t', '');
  if (stripped.length < 3) {
    return false;
  }
  final int char = stripped.codeUnitAt(0);
  if (char != 0x2D && char != 0x2A && char != 0x5F) {
    return false;
  }
  for (int i = 1; i < stripped.length; i++) {
    if (stripped.codeUnitAt(i) != char) {
      return false;
    }
  }
  return true;
}

MarkdownHeading? _heading(String line) {
  final String trimmed = line.trimLeft();
  int hashes = 0;
  while (hashes < trimmed.length && trimmed.codeUnitAt(hashes) == 0x23) {
    hashes++;
  }
  if (hashes == 0 || hashes > 6) {
    return null;
  }
  // `#hashtag` is a word, not a heading.
  if (hashes < trimmed.length && !_isSpaceOrTab(trimmed.codeUnitAt(hashes))) {
    return null;
  }
  String content = trimmed.substring(hashes).trim();
  // A closing run of hashes is decoration.
  int end = content.length;
  while (end > 0 && content.codeUnitAt(end - 1) == 0x23) {
    end--;
  }
  if (end != content.length &&
      (end == 0 || _isSpaceOrTab(content.codeUnitAt(end - 1)))) {
    content = content.substring(0, end).trimRight();
  }
  return MarkdownHeading(hashes > 3 ? 3 : hashes, parseInlineMarkdown(content));
}

/// The text of a `>` line, or null when the line is not quoted.
String? _quoteContent(String line) {
  int i = 0;
  while (i < line.length && i < 4 && _isSpaceOrTab(line.codeUnitAt(i))) {
    i++;
  }
  if (i >= line.length || line.codeUnitAt(i) != 0x3E) {
    return null;
  }
  i++;
  if (i < line.length && _isSpaceOrTab(line.codeUnitAt(i))) {
    i++;
  }
  return line.substring(i);
}

MarkdownBlock? _listItem(String line) {
  int i = 0;
  int columns = 0;
  while (i < line.length) {
    final int c = line.codeUnitAt(i);
    if (c == 0x20) {
      columns += 1;
    } else if (c == 0x09) {
      columns += 2;
    } else {
      break;
    }
    i++;
  }
  if (i >= line.length) {
    return null;
  }
  final int depth = columns ~/ 2;

  final int marker = line.codeUnitAt(i);
  if (marker == 0x2D || marker == 0x2A || marker == 0x2B) {
    if (i + 1 < line.length && !_isSpaceOrTab(line.codeUnitAt(i + 1))) {
      return null;
    }
    return MarkdownBullet(
      parseInlineMarkdown(line.substring(i + 1).trim()),
      depth,
    );
  }

  int digits = i;
  while (digits < line.length && _isDigit(line.codeUnitAt(digits))) {
    digits++;
  }
  if (digits == i || digits - i > 9 || digits >= line.length) {
    return null;
  }
  final int delimiter = line.codeUnitAt(digits);
  if (delimiter != 0x2E && delimiter != 0x29) {
    return null;
  }
  if (digits + 1 < line.length && !_isSpaceOrTab(line.codeUnitAt(digits + 1))) {
    return null;
  }
  return MarkdownNumbered(
    parseInlineMarkdown(line.substring(digits + 1).trim()),
    int.parse(line.substring(i, digits)),
    depth,
  );
}

// ---------------------------------------------------------------------------
// Inline parsing
// ---------------------------------------------------------------------------

/// Reads the inline markers of one block's text.
///
/// Exposed because every block type shares it, and because it is the half
/// worth testing directly.
List<MarkdownSpan> parseInlineMarkdown(String source) {
  final List<MarkdownSpan> spans = <MarkdownSpan>[];
  _scan(source, 0, source.length, const _Style(), spans, 0);
  return spans;
}

class _Style {
  const _Style({this.bold = false, this.italic = false, this.href});

  final bool bold;
  final bool italic;
  final String? href;

  _Style bolded() => _Style(bold: true, italic: italic, href: href);
  _Style italicised() => _Style(bold: bold, italic: true, href: href);
  _Style linked(String url) =>
      _Style(bold: bold, italic: italic, href: href ?? url);
}

void _scan(
  String s,
  int start,
  int end,
  _Style style,
  List<MarkdownSpan> out,
  int depth,
) {
  final StringBuffer buffer = StringBuffer();

  void flush() {
    if (buffer.isEmpty) {
      return;
    }
    _append(
      out,
      MarkdownSpan(
        buffer.toString(),
        bold: style.bold,
        italic: style.italic,
        href: style.href,
      ),
    );
    buffer.clear();
  }

  int i = start;
  while (i < end) {
    final int c = s.codeUnitAt(i);

    // An escape always wins, and a backslash before an ordinary character is
    // just a backslash — Windows paths survive.
    if (c == 0x5C) {
      if (i + 1 < end && _isEscapable(s.codeUnitAt(i + 1))) {
        buffer.write(s[i + 1]);
        i += 2;
      } else {
        buffer.write(r'\');
        i++;
      }
      continue;
    }

    // Code wins over everything inside it.
    if (c == 0x60) {
      int run = 1;
      while (i + run < end && s.codeUnitAt(i + run) == 0x60) {
        run++;
      }
      final int close = _findCodeClose(s, i + run, end, run);
      if (close >= 0) {
        flush();
        _append(
          out,
          MarkdownSpan(
            s.substring(i + run, close),
            code: true,
            href: style.href,
          ),
        );
        i = close + run;
      } else {
        buffer.write(s.substring(i, i + run));
        i += run;
      }
      continue;
    }

    if (c == 0x2A || c == 0x5F) {
      int run = 1;
      while (i + run < end && s.codeUnitAt(i + run) == c) {
        run++;
      }
      bool matched = false;
      if (depth < _maxNestingDepth) {
        for (final int need in run >= 2 ? const <int>[2, 1] : const <int>[1]) {
          if (!_opensEmphasis(s, i, need, start, end, c)) {
            continue;
          }
          final int close = _findEmphasisClose(s, i + need, end, c, need);
          if (close < 0) {
            continue;
          }
          flush();
          _scan(
            s,
            i + need,
            close,
            need == 2 ? style.bolded() : style.italicised(),
            out,
            depth + 1,
          );
          i = close + need;
          matched = true;
          break;
        }
      }
      if (!matched) {
        buffer.write(s.substring(i, i + run));
        i += run;
      }
      continue;
    }

    if (c == 0x5B && depth < _maxNestingDepth) {
      final int label = _findLabelEnd(s, i + 1, end);
      if (label > i + 1 && label + 1 < end && s.codeUnitAt(label + 1) == 0x28) {
        final int url = _findUrlEnd(s, label + 2, end);
        if (url > label + 2) {
          flush();
          _scan(
            s,
            i + 1,
            label,
            style.linked(s.substring(label + 2, url)),
            out,
            depth + 1,
          );
          i = url + 1;
          continue;
        }
      }
      buffer.write('[');
      i++;
      continue;
    }

    if (c == 0x3C) {
      final int close = _findAutolinkEnd(s, i, end);
      if (close > 0) {
        final String url = s.substring(i + 1, close);
        flush();
        _append(
          out,
          MarkdownSpan(
            url,
            bold: style.bold,
            italic: style.italic,
            href: style.href ?? url,
          ),
        );
        i = close + 1;
        continue;
      }
      buffer.write('<');
      i++;
      continue;
    }

    buffer.write(s[i]);
    i++;
  }

  flush();
}

/// Adds [span], merging it into the previous one when nothing about it
/// differs — a stray marker that stayed literal must not split a sentence into
/// two identical-looking runs.
void _append(List<MarkdownSpan> out, MarkdownSpan span) {
  if (span.text.isEmpty) {
    return;
  }
  if (out.isNotEmpty) {
    final MarkdownSpan last = out.last;
    if (last.bold == span.bold &&
        last.italic == span.italic &&
        last.code == span.code &&
        last.href == span.href) {
      out[out.length - 1] = MarkdownSpan(
        last.text + span.text,
        bold: last.bold,
        italic: last.italic,
        code: last.code,
        href: last.href,
      );
      return;
    }
  }
  out.add(span);
}

/// A run of exactly [need] backticks closes a code span.
int _findCodeClose(String s, int from, int end, int need) {
  int j = from;
  while (j < end) {
    if (s.codeUnitAt(j) != 0x60) {
      j++;
      continue;
    }
    int run = 1;
    while (j + run < end && s.codeUnitAt(j + run) == 0x60) {
      run++;
    }
    if (run == need) {
      return j;
    }
    j += run;
  }
  return -1;
}

/// Whether the run at [i] may open emphasis.
///
/// Conservative on purpose: the next character must not be whitespace (so
/// "5 * 3" stays arithmetic) and the previous one must not be alphanumeric (so
/// `snake_case_name` and `2*3*4` stay whole).
bool _opensEmphasis(String s, int i, int need, int start, int end, int ch) {
  if (i + need >= end) {
    return false;
  }
  if (i > start && _isWordChar(s.codeUnitAt(i - 1))) {
    return false;
  }
  return !_isWhitespace(s.codeUnitAt(i + need));
}

/// The index of the run that closes emphasis opened before [from], or -1.
///
/// Searches at most [_maxDelimiterSpan] characters, skips escapes, and steps
/// over code spans so a marker inside backticks cannot close emphasis outside
/// them.
int _findEmphasisClose(String s, int from, int end, int ch, int need) {
  final int limit = (end - from) > _maxDelimiterSpan
      ? from + _maxDelimiterSpan
      : end;
  int j = from;
  while (j < limit) {
    final int c = s.codeUnitAt(j);
    if (c == 0x5C) {
      j += 2;
      continue;
    }
    if (c == 0x60) {
      int run = 1;
      while (j + run < end && s.codeUnitAt(j + run) == 0x60) {
        run++;
      }
      final int close = _findCodeClose(s, j + run, end, run);
      j = close < 0 ? j + run : close + run;
      continue;
    }
    if (c == ch) {
      int run = 1;
      while (j + run < end && s.codeUnitAt(j + run) == ch) {
        run++;
      }
      // Non-empty content, a non-space before the marker, and no word
      // character straight after it.
      if (run >= need &&
          j > from &&
          !_isWhitespace(s.codeUnitAt(j - 1)) &&
          (j + need >= end || !_isWordChar(s.codeUnitAt(j + need)))) {
        return j;
      }
      j += run;
      continue;
    }
    j++;
  }
  return -1;
}

int _findLabelEnd(String s, int from, int end) {
  final int limit = (end - from) > _maxDelimiterSpan
      ? from + _maxDelimiterSpan
      : end;
  int nesting = 0;
  int j = from;
  while (j < limit) {
    final int c = s.codeUnitAt(j);
    if (c == 0x5C) {
      j += 2;
      continue;
    }
    if (c == 0x5B) {
      nesting++;
    } else if (c == 0x5D) {
      if (nesting == 0) {
        return j;
      }
      nesting--;
    }
    j++;
  }
  return -1;
}

/// The index of the `)` closing a link target, or -1. A target may not contain
/// whitespace — in prose, "(see above" is far more common than a wrapped url.
int _findUrlEnd(String s, int from, int end) {
  final int limit = (end - from) > _maxDelimiterSpan
      ? from + _maxDelimiterSpan
      : end;
  for (int j = from; j < limit; j++) {
    final int c = s.codeUnitAt(j);
    if (c == 0x29) {
      return j;
    }
    if (_isWhitespace(c) || c == 0x28) {
      return -1;
    }
  }
  return -1;
}

/// The index of the `>` closing a `<scheme://…>` autolink, or -1.
int _findAutolinkEnd(String s, int open, int end) {
  int j = open + 1;
  if (j >= end || !_isLetter(s.codeUnitAt(j))) {
    return -1;
  }
  while (j < end && _isSchemeChar(s.codeUnitAt(j))) {
    j++;
  }
  if (j + 2 >= end ||
      s.codeUnitAt(j) != 0x3A ||
      s.codeUnitAt(j + 1) != 0x2F ||
      s.codeUnitAt(j + 2) != 0x2F) {
    return -1;
  }
  j += 3;
  final int limit = (end - j) > _maxDelimiterSpan ? j + _maxDelimiterSpan : end;
  while (j < limit) {
    final int c = s.codeUnitAt(j);
    if (c == 0x3E) {
      return j > open + 1 ? j : -1;
    }
    if (_isWhitespace(c) || c == 0x3C) {
      return -1;
    }
    j++;
  }
  return -1;
}

// ---------------------------------------------------------------------------
// Character classes
// ---------------------------------------------------------------------------

bool _isSpaceOrTab(int c) => c == 0x20 || c == 0x09;

bool _isWhitespace(int c) =>
    c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0B || c == 0x0C || c == 0x0D;

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

bool _isLetter(int c) => (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);

/// Anything that can be part of a word — including every non-ASCII code unit,
/// so `słowo_ważne` is as safe from emphasis as `snake_case` is.
bool _isWordChar(int c) => _isLetter(c) || _isDigit(c) || c > 0x7F;

bool _isSchemeChar(int c) =>
    _isLetter(c) || _isDigit(c) || c == 0x2B || c == 0x2E || c == 0x2D;

/// ASCII punctuation — a backslash before any of it emits the literal
/// character, and a backslash before anything else stays a backslash.
bool _isEscapable(int c) =>
    (c >= 0x21 && c <= 0x2F) ||
    (c >= 0x3A && c <= 0x40) ||
    (c >= 0x5B && c <= 0x60) ||
    (c >= 0x7B && c <= 0x7E);

/// The capture's text with its markup taken off, for the places that render a
/// couple of lines of it in a fixed-height slot — the queue card's excerpt.
///
/// A card cannot render markdown: it prints three lines at one size, so a
/// heading would have to be drawn as body text anyway, and a bullet's marker
/// would be the second bullet the row already draws. What it *can* stop doing
/// is printing the markers themselves — a column of captures whose first line
/// is `## Plan` reads as a file listing rather than as notes.
///
/// Bounded by [maxChars] before parsing rather than after: an excerpt is three
/// lines, and a ninety-minute transcript must not be walked on every rebuild of
/// a row that will show 120 characters of it.
String markdownPreviewText(String source, {int maxChars = 400}) {
  final String head = source.length > maxChars
      ? source.substring(0, maxChars)
      : source;
  final StringBuffer buffer = StringBuffer();
  for (final MarkdownBlock block in parseSimpleMarkdown(head)) {
    final String line = switch (block) {
      MarkdownHeading(spans: final List<MarkdownSpan> spans) => _plain(spans),
      MarkdownParagraph(spans: final List<MarkdownSpan> spans) => _plain(spans),
      MarkdownBullet(spans: final List<MarkdownSpan> spans) => _plain(spans),
      MarkdownNumbered(spans: final List<MarkdownSpan> spans) => _plain(spans),
      MarkdownQuote(spans: final List<MarkdownSpan> spans) => _plain(spans),
      MarkdownCode(text: final String text) => text.trim(),
      MarkdownRule() => '',
    };
    if (line.isEmpty) continue;
    if (buffer.isNotEmpty) buffer.write('\n');
    buffer.write(line);
  }
  return buffer.toString();
}

String _plain(List<MarkdownSpan> spans) {
  final StringBuffer buffer = StringBuffer();
  for (final MarkdownSpan span in spans) {
    buffer.write(span.text);
  }
  return buffer.toString().trim();
}
