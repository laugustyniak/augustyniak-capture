/// What plays when the focus countdown reaches zero.
///
/// The clips are **vendored** under `assets/sounds/` for exactly the reason the
/// two font families are: the app is offline-first, and an alarm that only
/// rings once the device has network is not an alarm. They are short decaying
/// sines generated with ffmpeg, mono 22.05 kHz, peaking at -3 dBFS — pure tones
/// carry no harmonics above their fundamental, so that sample rate costs
/// nothing in fidelity and keeps all three under a quarter of a megabyte.
enum AlarmSound {
  /// The countdown still ends, it just ends quietly. Distinct from "no alarm
  /// configured": there is no such state, because a blank choice would have to
  /// be reported as an error nobody asked for — same reasoning as `vaultPath`.
  none('Silent', null, 'nothing plays — the dial alone reports the end'),
  chime('Chime', 'sounds/chime.wav', 'two soft tones, ~2 s'),
  bell('Bell', 'sounds/bell.wav', 'three ascending tones, ~2 s'),
  ping('Ping', 'sounds/ping.wav', 'one short tone, under a second');

  const AlarmSound(this.label, this.asset, this.blurb);

  final String label;

  /// Path **without** the `assets/` prefix, which is what `AssetSource` adds
  /// back. Null on [none], and that null is the whole implementation of silence.
  final String? asset;

  /// One line for the picker, so choosing does not require playing all four.
  final String blurb;

  bool get isAudible => asset != null;

  /// What ships, and what an unrecognised stored name falls back to.
  static const AlarmSound fallback = AlarmSound.chime;

  /// Unknown or absent degrades to [fallback], **not** to [none] — unlike
  /// `ShortcutAction.fromName`, which drops what it cannot read. A name written
  /// by a newer build means the user did choose a sound; answering with silence
  /// would turn that into an alarm that never rings and never says why, while
  /// the default at least rings.
  static AlarmSound fromName(String? name) =>
      AlarmSound.values.asNameMap()[name] ?? fallback;
}
