/// Where URLs opened on the running app arrive from.
///
/// The seam keeps `app_links` out of the dispatcher, so its tests drive a plain
/// stream and a platform without the plugin gets [NoopShortcutLinkSource].
abstract interface class ShortcutLinkSource {
  /// Every URL handed to the running instance, in arrival order. Not filtered:
  /// the OAuth callback comes through here too.
  Stream<Uri> get links;
}

class NoopShortcutLinkSource implements ShortcutLinkSource {
  const NoopShortcutLinkSource();

  @override
  Stream<Uri> get links => const Stream<Uri>.empty();
}
