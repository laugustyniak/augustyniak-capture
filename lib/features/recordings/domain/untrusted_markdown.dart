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
