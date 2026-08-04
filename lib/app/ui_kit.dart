import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Shared "Processing Console" palette and the small widgets every tab reuses.
/// Kept in one place so Queue, Models, Logs and Config stay visually identical.
///
/// Values come from the approved design (direction 1a, "console cards"). The
/// hairlines are deliberately *translucent* rather than flattened to an opaque
/// hex: the same border then reads correctly on the page background, on a card
/// and inside a bottom sheet, which are three different base colours.
class Console {
  const Console._();

  static const Color cyan = Color(0xFF22D3EE);
  static const Color background = Color(0xFF0A1322);
  static const Color surface = Color(0xFF101D31);

  /// Bottom navigation and filled input fields.
  static const Color surfaceDeep = Color(0xFF0C1728);

  /// Raised control on top of a card — the note button, a disabled fill.
  static const Color surfaceRaised = Color(0xFF14233A);

  /// The design's `rgba(126,155,196,.16)` hairline, kept translucent.
  static const Color border = Color(0x297E9BC4);

  /// Same hairline at `.35`, for a control that has to read as tappable.
  static const Color borderStrong = Color(0x597E9BC4);

  static const Color text = Color(0xFFE8F0FA);
  static const Color textSoft = Color(0xFFC8D7E4);

  /// Secondary label — meta lines, counters, unselected chips.
  static const Color muted = Color(0xFF8AA0BC);

  /// Icon tint on a raised control.
  static const Color mutedSoft = Color(0xFF9FB4D0);

  /// Tertiary *non-text* tint — a disabled control, a decorative fraction.
  ///
  /// Deliberately below the 4.5:1 text floor: at 3.4–4.0:1 against the four
  /// surfaces it is legal for graphics (3:1) and for a disabled affordance,
  /// which is exempt, and nothing else. Reach for [dimText] the moment the
  /// colour carries words.
  static const Color dim = Color(0xFF5F7695);

  /// Tertiary *label* — the verification footer, timestamps, hint text.
  ///
  /// Split out of [dim] because that value carried the whole `micro` scale at
  /// 10.5 px and 3.63:1 on a card, i.e. the app's entire layer of facts sat
  /// under AA. This one measures 5.19:1 on `surface` and 4.84:1 on
  /// `surfaceRaised`, while staying a clear step below [muted] (6.31:1) so the
  /// three-level hierarchy survives the fix.
  static const Color dimText = Color(0xFF7A90B0);

  static const Color green = Color(0xFF3DDC97);
  static const Color amber = Color(0xFFFBBF24);
  static const Color violet = Color(0xFFA78BFA);
  static const Color red = Color(0xFFFF7A7A);
  static const Color redSoft = Color(0xFFFF9B9B);

  /// Foreground on a cyan fill.
  static const Color ink = Color(0xFF06202B);

  /// Label colour on an unselected chip.
  static const Color chipLabel = muted;

  /// Background of a square icon tile (the leading badge on a card).
  static const Color iconTile = Color(0x1F22D3EE);

  /// Background of a square icon *button* (play, edit, copy).
  static const Color surfaceButton = Color(0xFF14233A);

  /// NavigationBar selection indicator. The design marks the active tab by
  /// colouring its icon and label, not with a pill behind them.
  static const Color navIndicator = Color(0x00000000);

  /// Confirmed-copy fill behind the check icon.
  static const Color greenDeep = Color(0xFF13301F);

  /// Error banner fill and its hairline.
  static const Color redDeep = Color(0xFF2A1220);
  static const Color redBorder = Color(0xFF5E2334);

  /// Unfilled part of any progress bar.
  static const Color track = Color(0x2E7E9BC4);

  /// Drop shadow under anything that floats over the list or the page.
  static const Color shadow = Color(0x80040A14);
}

/// The two families vendored under `assets/fonts`. Space Grotesk carries names
/// and headings; JetBrains Mono carries every machine-ish label — statuses,
/// counters, timers, file facts — which is what gives the app its console voice.
class ConsoleFont {
  const ConsoleFont._();

  static const String display = 'SpaceGrotesk';
  static const String mono = 'JetBrainsMono';
}

/// Named text styles from the design. Prefer these over ad-hoc `TextStyle`s so
/// the mono/display split stays consistent across tabs.
class ConsoleText {
  const ConsoleText._();

  /// `AUGUSTYNIAK CAPTURE` above a page title.
  static const TextStyle eyebrow = TextStyle(
    fontFamily: ConsoleFont.mono,
    fontSize: 10,
    fontWeight: FontWeight.w600,
    letterSpacing: 2.2,
    color: Console.cyan,
  );

  static const TextStyle pageTitle = TextStyle(
    fontFamily: ConsoleFont.display,
    fontSize: 26,
    height: 1.05,
    fontWeight: FontWeight.w700,
    color: Console.text,
  );

  /// Right-hand counter next to a page title.
  static const TextStyle counter = TextStyle(
    fontFamily: ConsoleFont.mono,
    fontSize: 11,
    fontWeight: FontWeight.w500,
    color: Console.muted,
  );

  static const TextStyle cardTitle = TextStyle(
    fontFamily: ConsoleFont.display,
    fontSize: 14,
    fontWeight: FontWeight.w600,
    color: Console.text,
  );

  /// The `14:52 · 16 kHz mono · 10:24` line under a card title.
  static const TextStyle cardMeta = TextStyle(
    fontFamily: ConsoleFont.mono,
    fontSize: 11,
    color: Console.muted,
  );

  /// Footer facts — `file verified · 6.8 MB · persisted`.
  static const TextStyle micro = TextStyle(
    fontFamily: ConsoleFont.mono,
    fontSize: 10.5,
    color: Console.dimText,
  );

  static const TextStyle pill = TextStyle(
    fontFamily: ConsoleFont.mono,
    fontSize: 10,
    fontWeight: FontWeight.w600,
  );

  static const TextStyle chip = TextStyle(
    fontFamily: ConsoleFont.mono,
    fontSize: 10.5,
    fontWeight: FontWeight.w600,
  );

  static const TextStyle navLabel = TextStyle(
    fontFamily: ConsoleFont.mono,
    fontSize: 10,
    fontWeight: FontWeight.w600,
  );

  /// Body copy inside a card or sheet.
  static const TextStyle body = TextStyle(
    fontFamily: ConsoleFont.display,
    fontSize: 12,
    height: 1.5,
    color: Console.textSoft,
  );
}

/// Caps how wide a tab's content grows, and centres it in whatever is left.
///
/// The design is a single column, and every tab draws one `ListView` with a
/// symmetric padding and no ceiling — which is invisible on a phone and wrong
/// on a desktop window. At 2000 px a card's three-line excerpt runs to roughly
/// 200 characters per line against a 45–75 optimum, and the action buttons sit
/// over a thousand pixels from the title they act on. This is the one place
/// that number lives; the shell wraps the whole `IndexedStack` in it, so the
/// cap cannot drift between tabs the way five separate paddings would.
class ConsolePageWidth extends StatelessWidget {
  const ConsolePageWidth({super.key, required this.child});

  /// About 90 characters of `ConsoleText.body`. Comfortably above the editor's
  /// own `_wideEnough = 460` breakpoint, so the two-column field layout still
  /// resolves to its wide form inside the cap.
  static const double maxWidth = 880;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}

/// The page header from the design: cyan eyebrow, large title, optional
/// right-hand counter. Replaces the `AppBar` — each tab draws its own so the
/// title can sit inside the scroll area.
class ConsoleHeader extends StatelessWidget {
  const ConsoleHeader({
    super.key,
    required this.title,
    this.trailing,
    this.eyebrow = 'AUGUSTYNIAK CAPTURE',
  });

  final String title;

  /// Small mono counter on the right, e.g. `12 captures`.
  final String? trailing;
  final String eyebrow;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(eyebrow, style: ConsoleText.eyebrow),
        const SizedBox(height: 4),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            Expanded(child: Text(title, style: ConsoleText.pageTitle)),
            if (trailing != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(trailing!, style: ConsoleText.counter),
              ),
          ],
        ),
      ],
    );
  }
}

/// Small filled circle that fades in and out, marking live work (a running
/// transcription, an armed recorder). Purely decorative — never the only signal
/// that something is happening, the adjacent label always says so too.
class PulseDot extends StatefulWidget {
  const PulseDot({super.key, required this.color, this.size = 6});

  final Color color;
  final double size;

  @override
  State<PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      // The design pulses to .25, not to nothing: a dot that vanishes reads as
      // a rendering glitch rather than a heartbeat.
      opacity: Tween<double>(begin: 1, end: .25).animate(_controller),
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
      ),
    );
  }
}

/// A soft band of light sweeping along a hairline — "this is being read right
/// now". Used for the enrichment pass, where the item is already `completed`
/// and durable and the only thing still running is a model looking at the text.
///
/// Deliberately *not* a `LinearProgressIndicator`: that one promises a job with
/// a beginning and an end that the queue is waiting on, which is what the
/// transcribing bar means. This one is a heartbeat, like [PulseDot] — it says
/// something is happening, never how far along it is.
///
/// Same caveat as [PulseDot]: it repeats forever, so a screen containing one
/// never reaches "no frames scheduled" and `pumpAndSettle` on it hangs. Pump
/// explicit frames instead.
class ScanLine extends StatefulWidget {
  const ScanLine({
    super.key,
    this.color = Console.cyan,
    this.height = 4,
    this.period = const Duration(milliseconds: 1400),
  });

  final Color color;
  final double height;
  final Duration period;

  @override
  State<ScanLine> createState() => _ScanLineState();
}

class _ScanLineState extends State<ScanLine>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.period,
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: SizedBox(
        height: widget.height,
        width: double.infinity,
        // The rail is drawn separately because `BoxDecoration` ignores `color`
        // as soon as a gradient is set — one decoration cannot carry both.
        child: ColoredBox(
          color: Console.track,
          child: AnimatedBuilder(
            animation: _controller,
            builder: (BuildContext context, Widget? _) {
              // The head travels past both edges, so the band slides in and out
              // rather than materialising at the ends — and the wrap from 1.4
              // back to -.4 happens while it is off-rail, so the loop is
              // seamless without needing a reversing curve.
              final double head = -.4 + 1.8 * _controller.value;
              return DecoratedBox(
                decoration: BoxDecoration(
                  // Five stops, not three: a bright core inside a wide soft
                  // halo. A single ramp fades so gradually that at 4 px the
                  // whole thing reads as a slightly uneven separator rather
                  // than as something moving.
                  gradient: LinearGradient(
                    colors: <Color>[
                      widget.color.withValues(alpha: 0),
                      widget.color.withValues(alpha: .35),
                      widget.color,
                      widget.color.withValues(alpha: .35),
                      widget.color.withValues(alpha: 0),
                    ],
                    stops: <double>[
                      (head - .3).clamp(0.0, 1.0),
                      (head - .09).clamp(0.0, 1.0),
                      head.clamp(0.0, 1.0),
                      (head + .09).clamp(0.0, 1.0),
                      (head + .3).clamp(0.0, 1.0),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Selectable pill used by every filter row (queue status, log level, audio
/// parameters). [selectedColor] is overridable because the log levels colour
/// their own chip.
///
/// The design draws these as *outlined* pills rather than solid fills: a row of
/// five solid chips competes with the cyan record button for attention, and the
/// selected one has to win that row without winning the screen.
/// Hover is carried by the border rather than by the Material ink: the chip's
/// unselected fill is transparent, so the ink *does* show through — but the
/// dark theme's hover overlay is white at 4% alpha over `#101D31`, which is at
/// the edge of visible. This is the most-clicked control in the app and it has
/// to answer a pointer.
class ConsoleChip extends StatefulWidget {
  const ConsoleChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
    this.selectedColor = Console.cyan,
    this.count,
  });

  final String label;
  final bool selected;
  final VoidCallback onSelected;
  final Color selectedColor;

  /// Rendered after the label (`READY 8`). Null hides it entirely — a chip with
  /// a bare `0` reads as broken, a chip with no count reads as a plain filter.
  final int? count;

  @override
  State<ConsoleChip> createState() => _ConsoleChipState();
}

class _ConsoleChipState extends State<ConsoleChip> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final bool selected = widget.selected;
    final Color foreground = selected
        ? widget.selectedColor
        : (_hovered || _focused ? Console.textSoft : Console.chipLabel);
    return Semantics(
      button: true,
      selected: selected,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: InkWell(
          onTap: widget.onSelected,
          borderRadius: BorderRadius.circular(999),
          onFocusChange: (bool value) => setState(() => _focused = value),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
            decoration: BoxDecoration(
              color: selected
                  ? widget.selectedColor.withValues(alpha: .14)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: selected
                    ? widget.selectedColor.withValues(alpha: .4)
                    : (_hovered || _focused
                          ? Console.borderStrong
                          : Console.border),
              ),
            ),
            child: Text(
              // Not uppercased here: some callers label chips with units
              // (`16 kHz`, `64 kbps`) that must keep their casing.
              widget.count == null
                  ? widget.label
                  : '${widget.label} ${widget.count}',
              style: ConsoleText.chip.copyWith(
                color: foreground,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Non-interactive square badge — the leading icon on a card or summary row.
class ConsoleIconTile extends StatelessWidget {
  const ConsoleIconTile({
    super.key,
    required this.icon,
    this.color = Console.cyan,
    this.background = Console.iconTile,
    this.size = 38,
    this.animate = false,
  });

  final IconData icon;
  final Color color;
  final Color background;
  final double size;

  /// The queue card cross-fades its tile colour when an item is reviewed.
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final BoxDecoration decoration = BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(10),
    );
    final Widget child = Icon(icon, color: color, size: size * .45);

    if (!animate) {
      return Container(
        width: size,
        height: size,
        decoration: decoration,
        child: child,
      );
    }
    return AnimatedContainer(
      duration: const Duration(milliseconds: 350),
      width: size,
      height: size,
      decoration: decoration,
      child: child,
    );
  }
}

/// [ConsoleIconTile]'s sibling for an item that has a picture of itself — the
/// poster frame pulled off a video. Same square, same 10 px radius, same size
/// contract, so a queue row is the identical shape whether or not a poster
/// exists.
///
/// The poster is a **derived** artifact: it can be absent, stale or truncated
/// (an ffmpeg that was killed mid-write), and none of that is an error worth
/// showing. So [errorBuilder] falls straight back to the plain icon tile and
/// the card degrades to exactly what it rendered before posters existed. The
/// widget stays stateless and synchronous on purpose — an `exists()` probe in
/// `build` would be an async gap on every scroll frame, and `Image.file`
/// already reports a missing file through the very same callback.
class ConsolePosterTile extends StatelessWidget {
  const ConsolePosterTile({
    super.key,
    required this.poster,
    required this.fallbackIcon,
    this.color = Console.cyan,
    this.background = Console.iconTile,
    this.size = 38,
  });

  /// The image to draw. Not required to exist — see [errorBuilder] above.
  final File poster;

  /// Drawn instead of the image whenever the file cannot be decoded.
  final IconData fallbackIcon;

  /// Fallback tint, so a failed item keeps its red icon when the poster is
  /// missing too.
  final Color color;
  final Color background;
  final double size;

  @override
  Widget build(BuildContext context) {
    final Widget fallback = ConsoleIconTile(
      icon: fallbackIcon,
      color: color,
      background: background,
      size: size,
    );
    // A 320 px JPEG in a 38 px slot: decode at the size actually painted
    // rather than holding the full bitmap in the image cache for every row.
    // The aspect-scoped lookup, not `maybeOf(...)?.devicePixelRatio`: the wide
    // form subscribes the tile to *every* metric, so raising the keyboard over
    // the Queue's search field would rebuild every poster in the list. The
    // `?? 1` is unreachable under the app's MaterialApp and exists only so the
    // widget can be pumped bare in a test.
    final double ratio = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;

    return SizedBox(
      width: size,
      height: size,
      child: DecoratedBox(
        // Behind the image, so the tile is never a hole in the row during the
        // frame or two the decode takes.
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(10),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.file(
            poster,
            width: size,
            height: size,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.medium,
            cacheWidth: (size * ratio).round(),
            // Keeps the previous frame while a re-extracted poster decodes,
            // instead of blinking back to the background.
            gaplessPlayback: true,
            errorBuilder: (BuildContext _, Object _, StackTrace? _) => fallback,
          ),
        ),
      ),
    );
  }
}

/// Tappable square icon button with the console's border treatment.
/// Square icon control — play, edit, copy-adjacent actions on a card.
///
/// Two desktop affordances live here rather than at the call sites, because
/// every icon action in the app funnels through this one widget:
///
/// - **The tooltip is [semanticLabel]**, which was already required and, until
///   now, only ever reached a screen reader. On a pointer the buttons said
///   nothing at all on hover.
/// - **Hover and focus repaint the border**, they do not rely on the Material
///   ink. That is not a preference: the ink splash is painted on the `Material`
///   *below* this widget's child, and the child is an opaque `Container`, so
///   the default hover and focus highlights are drawn where nothing can see
///   them. Anything that must be visible has to move the container's own
///   decoration.
class ConsoleIconButton extends StatefulWidget {
  const ConsoleIconButton({
    super.key,
    required this.icon,
    required this.onTap,
    required this.semanticLabel,
    this.active = false,
    this.size = 36,
    this.iconSize = 19,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String semanticLabel;

  /// Highlights the border and background, e.g. while a clip is playing.
  final bool active;
  final double size;
  final double iconSize;

  @override
  State<ConsoleIconButton> createState() => _ConsoleIconButtonState();
}

class _ConsoleIconButtonState extends State<ConsoleIconButton> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    // `active` is a state of the item (a clip is playing) and outranks a
    // pointer that merely passed over the button.
    final bool highlighted = widget.active || _hovered || _focused;
    return Semantics(
      button: true,
      label: widget.semanticLabel,
      child: Tooltip(
        message: widget.semanticLabel,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: InkResponse(
            onTap: widget.onTap,
            radius: 25,
            onFocusChange: (bool value) => setState(() => _focused = value),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              width: widget.size,
              height: widget.size,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: highlighted ? Console.iconTile : Console.surfaceButton,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: highlighted ? Console.cyan : Console.borderStrong,
                ),
              ),
              child: Icon(
                widget.icon,
                color: Console.cyan,
                size: widget.iconSize,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The app's one text input. Every field the user types into — the queue's
/// search box, the note composer, the inline card editor — is this shape: a
/// filled `surfaceDeep` well inside the same translucent hairline every other
/// control uses, going cyan on focus.
///
/// It exists because the theme carries no `inputDecorationTheme`: without it
/// each tab re-declared its own `OutlineInputBorder` and the three drifted. The
/// decoration is deliberately borderless *inside* — the container draws the
/// border — so a multi-line field and a one-line field are the same object at
/// two heights rather than two similar-looking widgets.
class ConsoleField extends StatelessWidget {
  const ConsoleField({
    super.key,
    required this.controller,
    this.focusNode,
    this.hintText,
    this.maxLines = 1,
    this.minLines,
    this.autofocus = false,
    this.textInputAction,
    this.onSubmitted,
    this.onChanged,
    this.fontSize = 13,
    this.monospace = false,
    this.prefixIcon,
    this.suffixIcon,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final String? hintText;
  final int? maxLines;
  final int? minLines;
  final bool autofocus;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final double fontSize;

  /// Machine-ish content (a tag, an endpoint) reads in JetBrains Mono; prose
  /// and names stay in the display face, like everywhere else in the app.
  final bool monospace;

  /// Optional leading/trailing affordances — the queue's magnifier and its
  /// clear button. Here rather than at the call site so a field with icons is
  /// still the same object as one without, which is what the search box stopped
  /// being when it grew its own `OutlineInputBorder`.
  final Widget? prefixIcon;
  final Widget? suffixIcon;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      focusNode: focusNode,
      autofocus: autofocus,
      maxLines: maxLines,
      minLines: minLines,
      textInputAction: textInputAction,
      onSubmitted: onSubmitted,
      onChanged: onChanged,
      cursorColor: Console.cyan,
      cursorWidth: 1.6,
      style: TextStyle(
        fontFamily: monospace ? ConsoleFont.mono : ConsoleFont.display,
        color: Console.text,
        fontSize: fontSize,
        height: 1.45,
      ),
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: Console.surfaceDeep,
        hintText: hintText,
        hintStyle: TextStyle(color: Console.dimText, fontSize: fontSize),
        prefixIcon: prefixIcon,
        prefixIconConstraints: const BoxConstraints(minWidth: 40),
        suffixIcon: suffixIcon,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 11,
          vertical: 10,
        ),
        border: _border(Console.border),
        enabledBorder: _border(Console.border),
        focusedBorder: _border(Console.cyan.withValues(alpha: .55)),
      ),
    );
  }

  static OutlineInputBorder _border(Color color) => OutlineInputBorder(
    borderRadius: const BorderRadius.all(Radius.circular(9)),
    borderSide: BorderSide(color: color),
  );
}

/// Confirmation for an action the user cannot undo. Returns false on dismiss,
/// so a barrier tap is never read as consent.
Future<bool> confirmDestructive(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
}) async {
  final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      backgroundColor: Console.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: Console.border),
      ),
      title: Text(
        title,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      content: Text(message, style: ConsoleText.body),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('CANCEL'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          style: TextButton.styleFrom(foregroundColor: Console.red),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

/// Copy-to-clipboard affordance, reusable by any tab that renders text worth
/// lifting out of the app.
///
/// Owns the short-lived "just copied" flag so the widgets embedding it can stay
/// stateless. Feedback is inline — the icon morphs into a check and settles
/// back — because the app deliberately uses no snackbars or dialogs anywhere.
class CopyButton extends StatefulWidget {
  const CopyButton({
    super.key,
    required this.text,
    this.tooltip = 'Copy text',
    this.semanticLabel = 'Copy text to clipboard',
  });

  /// Copied verbatim and in full, even when the caller renders it truncated.
  final String text;
  final String tooltip;
  final String semanticLabel;

  @override
  State<CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<CopyButton> {
  static const Duration _feedbackDuration = Duration(milliseconds: 1600);

  Timer? _resetTimer;
  bool _copied = false;
  bool _hovered = false;
  bool _focused = false;

  @override
  void dispose() {
    // A card can leave the tree while the timer is still pending; without this
    // the callback would fire setState on a disposed element.
    _resetTimer?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (!mounted) return;
    setState(() => _copied = true);
    _resetTimer?.cancel();
    _resetTimer = Timer(_feedbackDuration, () {
      if (mounted) {
        setState(() => _copied = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: _copied ? 'Text copied to clipboard' : widget.semanticLabel,
      child: Tooltip(
        message: _copied ? 'Copied' : widget.tooltip,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: InkResponse(
            onTap: _copy,
            radius: 22,
            onFocusChange: (bool value) => setState(() => _focused = value),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 260),
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _copied ? Console.greenDeep : Console.surfaceButton,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: _copied
                      ? Console.green
                      : (_hovered || _focused
                            ? Console.cyan
                            : Console.borderStrong),
                ),
              ),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 260),
                transitionBuilder: (Widget child, Animation<double> animation) {
                  return ScaleTransition(
                    scale: CurvedAnimation(
                      parent: animation,
                      curve: Curves.easeOutBack,
                    ),
                    child: FadeTransition(opacity: animation, child: child),
                  );
                },
                child: Icon(
                  _copied ? Icons.check_rounded : Icons.copy_rounded,
                  key: ValueKey<bool>(_copied),
                  color: _copied ? Console.green : Console.muted,
                  size: 17,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.label,
    required this.color,
    this.pulse = false,
    this.outlined = false,
  });

  final String label;
  final Color color;

  /// Prefixes a pulsing dot — reserved for a state that is actively changing
  /// (transcribing, recording), never for a resting one.
  final bool pulse;

  /// Draws the pill as an outline instead of a fill.
  ///
  /// The card can carry three of these at once — project, category and pipeline
  /// status — and only the last is a *state*. Given identical form they had
  /// identical weight, so colour alone had to carry the difference between
  /// "this belongs to Acme" and "this is still running", at 10 px. The fill is
  /// now reserved for the one that changes on its own; the other two are
  /// labels, and read as labels.
  final bool outlined;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: outlined ? null : color.withValues(alpha: .1),
        border: outlined
            ? Border.all(color: color.withValues(alpha: .45))
            : null,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (pulse) ...<Widget>[
            PulseDot(color: color),
            const SizedBox(width: 6),
          ],
          Text(label, style: ConsoleText.pill.copyWith(color: color)),
        ],
      ),
    );
  }
}

class ErrorBanner extends StatelessWidget {
  const ErrorBanner({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(18, 4, 18, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Console.redDeep,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Console.redBorder),
      ),
      child: Row(
        children: <Widget>[
          const Icon(Icons.error_outline, color: Console.redSoft, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: ConsoleText.micro.copyWith(color: Console.redSoft),
            ),
          ),
        ],
      ),
    );
  }
}

/// Uppercase section heading with an optional right-hand counter, e.g.
/// `PROVIDER PROFILES   3 ITEMS`.
class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.title, this.trailing});

  final String title;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: <Widget>[
        Text(
          title,
          style: ConsoleText.chip.copyWith(
            fontSize: 11,
            letterSpacing: 1.1,
            color: Console.muted,
          ),
        ),
        if (trailing != null)
          Text(
            trailing!,
            style: ConsoleText.micro.copyWith(fontWeight: FontWeight.w500),
          ),
      ],
    );
  }
}

/// Bordered panel used for every non-list block (forms, info rows, warnings).
class ConsoleCard extends StatelessWidget {
  const ConsoleCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.accent,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: Console.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent ?? Console.border),
      ),
      child: child,
    );
  }
}

class EmptyPanel extends StatelessWidget {
  const EmptyPanel({
    super.key,
    required this.icon,
    required this.title,
    required this.blurb,
  });

  final IconData icon;
  final String title;
  final String blurb;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 40),
      decoration: BoxDecoration(
        color: Console.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Console.border),
      ),
      child: Column(
        children: <Widget>[
          Icon(icon, size: 36, color: Console.cyan),
          const SizedBox(height: 14),
          Text(
            title,
            textAlign: TextAlign.center,
            style: ConsoleText.cardTitle,
          ),
          const SizedBox(height: 7),
          Text(blurb, textAlign: TextAlign.center, style: ConsoleText.micro),
        ],
      ),
    );
  }
}

/// Key/value row for read-only facts (paths, counts, active model).
class InfoRow extends StatelessWidget {
  const InfoRow({
    super.key,
    required this.label,
    required this.value,
    this.valueColor,
    this.monospace = false,
  });

  final String label;
  final String value;
  final Color? valueColor;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: ConsoleText.micro.copyWith(
                fontSize: 9.5,
                fontWeight: FontWeight.w600,
                letterSpacing: .6,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: valueColor ?? Console.textSoft,
                fontSize: 11,
                height: 1.4,
                // Everything factual already reads as mono; the flag now only
                // decides whether the *value* joins it or stays in the display
                // face (a provider name, a free-text note).
                fontFamily: monospace ? ConsoleFont.mono : ConsoleFont.display,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String formatDuration(Duration duration) {
  final String minutes = duration.inMinutes
      .remainder(60)
      .toString()
      .padLeft(2, '0');
  final String seconds = duration.inSeconds
      .remainder(60)
      .toString()
      .padLeft(2, '0');
  return '$minutes:$seconds';
}

/// `6.8 MB`, `2 KB`, `812 B`. Returns null below one byte so a caller can drop
/// the segment entirely rather than print `0 B` for a legacy row that never
/// recorded its size.
String? formatBytes(int bytes) {
  if (bytes <= 0) return null;
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String formatDateTime(DateTime value) {
  final DateTime local = value.toLocal();
  return '${local.year}-${_two(local.month)}-${_two(local.day)} '
      '${_two(local.hour)}:${_two(local.minute)}';
}

String formatClock(DateTime value) {
  final DateTime local = value.toLocal();
  return '${_two(local.hour)}:${_two(local.minute)}:${_two(local.second)}';
}

/// `17:09` — the wall clock without seconds. Distinct from [formatClock], which
/// is a running timer and needs them, and from [formatDateTime], which is the
/// full stamp the meta line already prints.
String formatTimeOfDay(DateTime value) {
  final DateTime local = value.toLocal();
  return '${_two(local.hour)}:${_two(local.minute)}';
}

String _two(int value) => value.toString().padLeft(2, '0');
