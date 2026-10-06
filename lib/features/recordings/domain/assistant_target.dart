/// Where a launch should go, and whether the prompt can travel with it.
///
/// [needsClipboard] means the prompt will **not** be in [uri]: the caller must
/// put it on the clipboard first and the user pastes it. [uri] is then the bare
/// page, never a truncated prompt.
typedef AssistantLaunch = ({Uri uri, bool needsClipboard});

/// A general-purpose assistant a capture can be sent to by opening a link.
///
/// One definition per service, so a service that drops (or gains) prefill is a
/// one-line change here rather than a hunt through the UI. **None of these
/// query parameters is a documented API** except Claude Desktop's — see
/// `docs/plans/2026-10-06-send-to-any-assistant.md` ("Spike results").
enum AssistantTarget {
  /// `claude://` is registered by Claude Desktop. The link prefills a new chat
  /// and does not send it.
  claudeDesktop(
    label: 'Claude Desktop',
    domain: 'claude.ai',
    autoSubmits: false,
    supportsPrefill: true,
    isWeb: false,
  ),

  /// Reports differ on whether `?q=` sends, so it is labelled as if it does:
  /// the safer error for a button that publishes text to a third party.
  claudeWeb(
    label: 'Claude',
    domain: 'claude.ai',
    autoSubmits: true,
    supportsPrefill: true,
  ),
  chatgpt(
    label: 'ChatGPT',
    domain: 'chatgpt.com',
    autoSubmits: true,
    supportsPrefill: true,
  ),
  perplexity(
    label: 'Perplexity',
    domain: 'www.perplexity.ai',
    autoSubmits: true,
    supportsPrefill: true,
  ),

  /// Verified: `gemini.google.com/app?q=` loads with an empty box.
  gemini(
    label: 'Gemini',
    domain: 'gemini.google.com',
    autoSubmits: false,
    supportsPrefill: false,
  );

  const AssistantTarget({
    required this.label,
    required this.domain,
    required this.autoSubmits,
    required this.supportsPrefill,
    this.isWeb = true,
  });

  /// What the button says.
  final String label;

  /// Shown on the button. Sending publishes the capture's text to a third
  /// party, and the user should see where it goes before pressing, not
  /// discover it afterwards.
  final String domain;

  /// True when opening the link sends the prompt with no further click, which
  /// makes the sheet's prompt field the user's last chance to edit it.
  final bool autoSubmits;

  final bool supportsPrefill;

  /// False only for the desktop app's own scheme.
  final bool isWeb;

  /// Longest encoded URL a web target is sent. Cloudflare rejects request lines
  /// above ~16 KB and every non-ASCII character costs six encoded characters
  /// (`ż` → `%C5%BC`), so this is measured on the *encoded* string, with margin.
  static const int maxWebUrlLength = 8000;

  /// Longest decoded prompt Claude Desktop is sent. Desktop truncates at about
  /// 14,000 characters itself; this leaves margin.
  static const int maxDesktopPromptLength = 12000;

  /// The `RouteRecord.target` written for a delivery to this service.
  String get routeTarget => isWeb ? '$label · web' : label;

  Uri get _bare => switch (this) {
    claudeDesktop => Uri(scheme: 'claude', host: 'claude.ai', path: '/new'),
    claudeWeb => Uri.https('claude.ai', '/new'),
    chatgpt => Uri.https('chatgpt.com', '/'),
    perplexity => Uri.https('www.perplexity.ai', '/search'),
    gemini => Uri.https('gemini.google.com', '/app'),
  };

  /// What to open for [prompt].
  ///
  /// The query goes through [Uri], never string concatenation, so encoding is
  /// the URI class's job. **A long prompt is never truncated to fit:** past the
  /// limit — or for a target with no prefill — the answer is the bare page and
  /// [AssistantLaunch.needsClipboard].
  AssistantLaunch launchFor(String prompt) {
    final Uri bare = _bare;
    final bool bareOnly = !supportsPrefill;
    if (bareOnly) return (uri: bare, needsClipboard: true);

    final Uri full = bare.replace(
      queryParameters: <String, String>{'q': prompt},
    );
    final bool tooLong = isWeb
        ? full.toString().length > maxWebUrlLength
        : prompt.length > maxDesktopPromptLength;
    if (tooLong) return (uri: bare, needsClipboard: true);
    return (uri: full, needsClipboard: false);
  }
}
