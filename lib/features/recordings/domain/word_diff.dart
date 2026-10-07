/// How a run of words differs between two texts.
enum DiffKind { same, removed, added }

class DiffSpan {
  const DiffSpan(this.kind, this.text);

  final DiffKind kind;

  /// The words of this run, with the whitespace that followed each.
  final String text;
}

/// A word-level diff of [before] against [after], for the clean-up review
/// (#258). Whitespace stays attached to the word before it, so joining every
/// span's text in order gives back [before] (same + removed) or [after]
/// (same + added) exactly.
///
/// Longest common subsequence over words. Quadratic, so it is bounded:
/// past [maxWords] on either side it returns null and the caller shows the two
/// texts without highlighting rather than freezing a frame.
List<DiffSpan>? wordDiff(String before, String after, {int maxWords = 2500}) {
  final List<String> a = _words(before);
  final List<String> b = _words(after);
  if (a.length > maxWords || b.length > maxWords) return null;

  // lcs[i][j] = length of the LCS of a[i..] and b[j..], compared on the word
  // itself — a change in the trailing whitespace alone is not a change.
  final List<List<int>> lcs = List<List<int>>.generate(
    a.length + 1,
    (_) => List<int>.filled(b.length + 1, 0),
  );
  for (int i = a.length - 1; i >= 0; i--) {
    for (int j = b.length - 1; j >= 0; j--) {
      lcs[i][j] = a[i].trim() == b[j].trim()
          ? lcs[i + 1][j + 1] + 1
          : (lcs[i + 1][j] >= lcs[i][j + 1] ? lcs[i + 1][j] : lcs[i][j + 1]);
    }
  }

  final List<DiffSpan> spans = <DiffSpan>[];
  void push(DiffKind kind, String word) {
    if (spans.isNotEmpty && spans.last.kind == kind) {
      spans[spans.length - 1] = DiffSpan(kind, spans.last.text + word);
    } else {
      spans.add(DiffSpan(kind, word));
    }
  }

  int i = 0;
  int j = 0;
  while (i < a.length && j < b.length) {
    if (a[i].trim() == b[j].trim()) {
      push(DiffKind.same, b[j]);
      i++;
      j++;
    } else if (lcs[i + 1][j] >= lcs[i][j + 1]) {
      push(DiffKind.removed, a[i++]);
    } else {
      push(DiffKind.added, b[j++]);
    }
  }
  while (i < a.length) {
    push(DiffKind.removed, a[i++]);
  }
  while (j < b.length) {
    push(DiffKind.added, b[j++]);
  }
  return spans;
}

/// Each word with the whitespace that follows it; leading whitespace rides
/// the first word.
List<String> _words(String text) =>
    RegExp(r'\s*\S+\s*').allMatches(text).map((Match m) => m[0]!).toList();
