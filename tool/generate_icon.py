#!/usr/bin/env python3
"""Generate the Audivoa Core app icon for every platform.

Draws the "Processing Console" mark — cyan waveform bars on the console
navy panel with the app's translucent hairline border — in three styles:

  rounded     rounded panel, transparent corners (desktop / Linux)
  flat        full-bleed opaque square, no border — iOS masks its own
              corners and rejects icons that carry an alpha channel
  foreground  bars only on a transparent canvas, scaled into the
              adaptive-icon safe zone (Android; doubles as the
              monochrome layer for Android 13 themed icons, which
              reads only the alpha channel)

Colors mirror `Console` in lib/app/ui_kit.dart; keep them in sync.

Usage:
    python3 tool/generate_icon.py                       # 1024 px master
    python3 tool/generate_icon.py --sizes-dir out/ 512 256 128
    python3 tool/generate_icon.py --android-res android/app/src/main/res
    python3 tool/generate_icon.py \\
        --ios-appiconset ios/Runner/Assets.xcassets/AppIcon.appiconset
"""

import argparse
import json
import pathlib

from PIL import Image, ImageDraw

MASTER = 1024
SUPERSAMPLE = 4

PANEL = (16, 29, 49, 255)        # Console navy #101D31
HAIRLINE = (126, 155, 196, 41)   # translucent hairline 0x297E9BC4
ACCENT = (34, 211, 238, 255)     # cyan #22D3EE

CORNER_RADIUS = 0.22             # of edge length
BAR_WIDTH = 64 / MASTER
BAR_GAP = 44 / MASTER
BAR_HEIGHTS = (0.26, 0.46, 0.72, 0.58, 0.40, 0.62, 0.30)
BORDER_WIDTH = 10 / MASTER

# Adaptive icons show roughly the middle 72dp of the 108dp canvas and mask
# it to the launcher's shape; the guaranteed-visible safe zone is a centred
# 66dp circle. 0.58 keeps the bars' bounding box inside that circle.
FOREGROUND_SCALE = 0.58

# ic_launcher_foreground.png per density (108dp adaptive canvas).
ANDROID_FOREGROUND = {
    "mipmap-mdpi": 108,
    "mipmap-hdpi": 162,
    "mipmap-xhdpi": 216,
    "mipmap-xxhdpi": 324,
    "mipmap-xxxhdpi": 432,
}

# Legacy ic_launcher.png per density (48dp), pre-API-26 launchers.
ANDROID_LEGACY = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}

ADAPTIVE_ICON_XML = """\
<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
    <monochrome android:drawable="@mipmap/ic_launcher_foreground"/>
</adaptive-icon>
"""

BACKGROUND_COLOR_XML = """\
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <!-- Console navy; keep in sync with PANEL in tool/generate_icon.py. -->
    <color name="ic_launcher_background">#101D31</color>
</resources>
"""


def _draw_bars(draw: ImageDraw.ImageDraw, s: float, scale: float) -> None:
    bar_w = s * BAR_WIDTH * scale
    gap = s * BAR_GAP * scale
    total = len(BAR_HEIGHTS) * bar_w + (len(BAR_HEIGHTS) - 1) * gap
    x = (s - total) / 2
    cy = s / 2
    for frac in BAR_HEIGHTS:
        half = s * frac * scale / 2
        draw.rounded_rectangle(
            (x, cy - half, x + bar_w, cy + half),
            radius=bar_w / 2,
            fill=ACCENT,
        )
        x += bar_w + gap


def render(size: int, style: str = "rounded") -> Image.Image:
    s = size * SUPERSAMPLE
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    if style == "rounded":
        radius = s * CORNER_RADIUS
        draw.rounded_rectangle((0, 0, s - 1, s - 1), radius=radius, fill=PANEL)
        border = max(1, round(s * BORDER_WIDTH))
        draw.rounded_rectangle(
            (border // 2, border // 2, s - 1 - border // 2, s - 1 - border // 2),
            radius=radius - border // 2,
            outline=HAIRLINE,
            width=border,
        )
        _draw_bars(draw, s, 1.0)
    elif style == "flat":
        draw.rectangle((0, 0, s, s), fill=PANEL)
        _draw_bars(draw, s, 1.0)
    elif style == "foreground":
        _draw_bars(draw, s, FOREGROUND_SCALE)
    else:
        raise ValueError(f"unknown style: {style}")

    out = img.resize((size, size), Image.LANCZOS)
    if style == "flat":
        out = out.convert("RGB")  # iOS rejects icons with an alpha channel
    return out


def write_android(res: pathlib.Path) -> None:
    for density, px in ANDROID_LEGACY.items():
        out = res / density / "ic_launcher.png"
        out.parent.mkdir(parents=True, exist_ok=True)
        render(px, "rounded").save(out)
        print(f"wrote {out}")
    for density, px in ANDROID_FOREGROUND.items():
        out = res / density / "ic_launcher_foreground.png"
        render(px, "foreground").save(out)
        print(f"wrote {out}")
    xml = res / "mipmap-anydpi-v26" / "ic_launcher.xml"
    xml.parent.mkdir(parents=True, exist_ok=True)
    xml.write_text(ADAPTIVE_ICON_XML)
    print(f"wrote {xml}")
    color = res / "values" / "ic_launcher_background.xml"
    color.write_text(BACKGROUND_COLOR_XML)
    print(f"wrote {color}")


def write_ios(appiconset: pathlib.Path) -> None:
    contents = json.loads((appiconset / "Contents.json").read_text())
    for image in contents["images"]:
        points = float(image["size"].split("x")[0])
        scale = int(image["scale"].rstrip("x"))
        px = round(points * scale)
        out = appiconset / image["filename"]
        render(px, "flat").save(out)
        print(f"wrote {out} ({px} px)")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--master",
        type=pathlib.Path,
        default=pathlib.Path(__file__).resolve().parent.parent
        / "assets"
        / "icon"
        / "app_icon_1024.png",
    )
    parser.add_argument("--sizes-dir", type=pathlib.Path, default=None)
    parser.add_argument("--android-res", type=pathlib.Path, default=None)
    parser.add_argument("--ios-appiconset", type=pathlib.Path, default=None)
    parser.add_argument("sizes", type=int, nargs="*", default=[])
    args = parser.parse_args()

    args.master.parent.mkdir(parents=True, exist_ok=True)
    render(MASTER).save(args.master)
    print(f"wrote {args.master}")

    if args.sizes_dir:
        args.sizes_dir.mkdir(parents=True, exist_ok=True)
        for size in args.sizes or [512, 256, 128, 64, 48, 32, 16]:
            out = args.sizes_dir / f"app_icon_{size}.png"
            render(size).save(out)
            print(f"wrote {out}")

    if args.android_res:
        write_android(args.android_res)

    if args.ios_appiconset:
        write_ios(args.ios_appiconset)


if __name__ == "__main__":
    main()
