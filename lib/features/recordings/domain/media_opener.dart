/// Seam for handing a source file to the platform's own player/viewer.
///
/// Playback is deliberately **external**: the app targets desktop Linux first,
/// where no in-process video widget exists, and shelling out to whatever the
/// user already has configured beats bundling a second decoder. Mirrors
/// [ClipboardSink]: it defaults to a no-op so the pure-Dart tests need no
/// Flutter binding, and the real implementation lives in `data/` because only
/// that layer may touch the platform.
///
/// Unlike [ClipboardSink] this one **does** throw: it runs from a user tap, not
/// from the capture pipeline, so a failure has somewhere to be shown.
abstract interface class MediaOpener {
  Future<void> open(String path);
}

class NoopMediaOpener implements MediaOpener {
  const NoopMediaOpener();

  @override
  Future<void> open(String path) async {}
}
