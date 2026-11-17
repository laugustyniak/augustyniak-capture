import 'package:app_links/app_links.dart';

import '../domain/shortcut_link_source.dart';

/// URLs forwarded to the running instance through `app_links` — on Linux the
/// path is GApplication `command-line` → the `gtk` plugin → `app_links`, the
/// same one the OAuth callback takes.
///
/// A cold-start URL is deliberately not read from here: the Linux runner hands
/// it to Dart as an entrypoint argument and strips it from the command line,
/// so it reaches `ShortcutLinkDispatcher` exactly once.
class AppLinksShortcutLinkSource implements ShortcutLinkSource {
  AppLinksShortcutLinkSource([AppLinks? appLinks])
    : _appLinks = appLinks ?? AppLinks();

  final AppLinks _appLinks;

  @override
  Stream<Uri> get links => _appLinks.uriLinkStream;
}
