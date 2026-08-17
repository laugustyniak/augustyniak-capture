/// One speech model that can be installed on this machine.
///
/// A static catalog, like `ProviderPreset.all` and for the same reason: the
/// list is small, it changes rarely, and shipping it beats asking the user to
/// paste a URL for a 1.5 GB binary whose name has to be exactly right.
class WhisperModel {
  const WhisperModel({
    required this.id,
    required this.label,
    required this.url,
    required this.approximateBytes,
    required this.note,
    this.sha256,
  });

  /// Stable across releases: it names the file on disk and it is what a local
  /// `ProviderProfile` stores in its `model` field. Renaming one orphans every
  /// profile pointing at it.
  final String id;

  final String label;
  final Uri url;

  /// **Approximate, and for display only.** It sizes the download before it
  /// starts so a user on a phone can decide; nothing verifies against it.
  /// Truncation is caught by comparing what arrived against the
  /// `Content-Length` the server actually promised, which needs no catalog
  /// number and cannot go stale.
  final int approximateBytes;

  /// What this one is for, in one line — the trade being made is size against
  /// accuracy, and a list of file names does not say that.
  final String note;

  /// Pinned integrity, when it is known.
  ///
  /// **Null here means unpinned, not "no check".** Every entry this app ships
  /// is currently unpinned: a hash can only be stated by downloading the file
  /// and computing it, and inventing one would be worse than admitting there
  /// is none — a wrong pin refuses every honest download while a fabricated
  /// one that happens to match nothing is a check that never runs.
  ///
  /// The store verifies against this when it is present and reports the
  /// install as unverified when it is not, so the difference reaches the user
  /// instead of being smoothed over. Pinning them is tracked separately.
  final String? sha256;

  /// `ggml-base-q5_1.bin`
  String get fileName => 'ggml-$id.bin';
}

/// The models this app offers.
///
/// **Quantized variants first.** A `q5_1` model is roughly a third of the size
/// of its `f16` sibling for a small accuracy cost, and on the platform this
/// feature matters most — a phone, offline — size is the binding constraint.
///
/// The URLs follow the published `ggml-<id>.bin` naming on the whisper.cpp
/// model repository. Sizes are approximate and rounded; see
/// [WhisperModel.approximateBytes] for why nothing verifies against them.
class WhisperModelCatalog {
  const WhisperModelCatalog._();

  static const String _base =
      'https://huggingface.co/ggerganov/whisper.cpp/resolve/main';

  static final List<WhisperModel> all = <WhisperModel>[
    WhisperModel(
      id: 'tiny-q5_1',
      label: 'Tiny (quantized)',
      url: Uri.parse('$_base/ggml-tiny-q5_1.bin'),
      approximateBytes: 32 * 1024 * 1024,
      note: 'Smallest and fastest. Usable for short, clear dictation.',
    ),
    WhisperModel(
      id: 'base-q5_1',
      label: 'Base (quantized)',
      url: Uri.parse('$_base/ggml-base-q5_1.bin'),
      approximateBytes: 60 * 1024 * 1024,
      note: 'The sensible default on a phone.',
    ),
    WhisperModel(
      id: 'small-q5_1',
      label: 'Small (quantized)',
      url: Uri.parse('$_base/ggml-small-q5_1.bin'),
      approximateBytes: 190 * 1024 * 1024,
      note: 'Noticeably better on accented and inflected speech.',
    ),
    WhisperModel(
      id: 'medium-q5_0',
      label: 'Medium (quantized)',
      url: Uri.parse('$_base/ggml-medium-q5_0.bin'),
      approximateBytes: 540 * 1024 * 1024,
      note: 'Desktop-sized. Slow on a phone, and worth it on a laptop.',
    ),
  ];

  /// Null for an id this build does not ship, which is what a profile pointing
  /// at a retired model resolves to — the same dangling-reference shape as a
  /// deleted project on a capture.
  static WhisperModel? byId(String id) {
    for (final WhisperModel model in all) {
      if (model.id == id) return model;
    }
    return null;
  }
}
