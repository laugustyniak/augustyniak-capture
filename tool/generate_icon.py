#!/usr/bin/env python3
"""Generate the Audivoa Core app icon.

Draws the "Processing Console" mark — cyan waveform bars on the console
navy panel with the app's translucent hairline border — and writes a
1024 px master PNG plus any requested derived sizes.

Colors mirror `Console` in lib/app/ui_kit.dart; keep them in sync.

Usage:
    python3 tool/generate_icon.py                       # master only
    python3 tool/generate_icon.py --sizes-dir out/ 512 256 128 64 48 32 16
"""

import argparse
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


def render(size: int) -> Image.Image:
    s = size * SUPERSAMPLE
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    radius = s * CORNER_RADIUS
    draw.rounded_rectangle((0, 0, s - 1, s - 1), radius=radius, fill=PANEL)

    border = max(1, round(s * BORDER_WIDTH))
    draw.rounded_rectangle(
        (border // 2, border // 2, s - 1 - border // 2, s - 1 - border // 2),
        radius=radius - border // 2,
        outline=HAIRLINE,
        width=border,
    )

    bar_w = s * BAR_WIDTH
    gap = s * BAR_GAP
    total = len(BAR_HEIGHTS) * bar_w + (len(BAR_HEIGHTS) - 1) * gap
    x = (s - total) / 2
    cy = s / 2
    for frac in BAR_HEIGHTS:
        half = s * frac / 2
        draw.rounded_rectangle(
            (x, cy - half, x + bar_w, cy + half),
            radius=bar_w / 2,
            fill=ACCENT,
        )
        x += bar_w + gap

    return img.resize((size, size), Image.LANCZOS)


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


if __name__ == "__main__":
    main()
