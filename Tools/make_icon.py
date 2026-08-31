#!/usr/bin/env python3
"""Draw Pdf2Score's app icon and pack it into an .icns.

Run with the project's venv python (Pillow lives there). Uses macOS's own
iconutil for the final container.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw

SIZES = [16, 32, 64, 128, 256, 512, 1024]
ICONSET = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]

INK = (28, 30, 38, 255)
PAPER = (250, 249, 245, 255)


def rounded_mask(size: int, radius_ratio: float = 0.2237) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle(
        [(0, 0), (size - 1, size - 1)], radius=int(size * radius_ratio), fill=255
    )
    return mask


def vertical_gradient(size: int, top: tuple[int, ...], bottom: tuple[int, ...]) -> Image.Image:
    gradient = Image.new("RGBA", (1, size))
    for y in range(size):
        t = y / max(size - 1, 1)
        gradient.putpixel(
            (0, y),
            tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(4)),
        )
    return gradient.resize((size, size))


def draw_icon(size: int) -> Image.Image:
    scale = size / 1024.0

    def s(value: float) -> float:
        return value * scale

    canvas = vertical_gradient(size, (74, 108, 214, 255), (38, 58, 140, 255))
    canvas.putalpha(rounded_mask(size))

    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)

    # A sheet of paper, tilted slightly so it reads as a page rather than a box.
    page = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    page_draw = ImageDraw.Draw(page)
    page_draw.rounded_rectangle(
        [(s(232), s(168)), (s(792), s(856))], radius=s(28), fill=PAPER
    )
    # Staff lines.
    for index in range(5):
        y = s(360 + index * 46)
        page_draw.line([(s(300), y), (s(724), y)], fill=(150, 156, 172, 255), width=max(1, int(s(9))))
    for index in range(5):
        y = s(620 + index * 46)
        page_draw.line([(s(300), y), (s(724), y)], fill=(150, 156, 172, 255), width=max(1, int(s(9))))
    layer.alpha_composite(page)

    # A single quarter note sitting on the upper staff.
    draw.ellipse([(s(360), s(430)), (s(492), s(524))], fill=INK)
    draw.rectangle([(s(468), s(276)), (s(496), s(478))], fill=INK)
    draw.polygon(
        [(s(496), s(276)), (s(628), s(340)), (s(628), s(424)), (s(496), s(360))], fill=INK
    )

    canvas.alpha_composite(layer)
    return canvas


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: make_icon.py <output.icns>", file=sys.stderr)
        return 2
    output = sys.argv[1]
    os.makedirs(os.path.dirname(output) or ".", exist_ok=True)

    master = {size: draw_icon(size) for size in SIZES}

    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, "AppIcon.iconset")
        os.makedirs(iconset)
        for base, factor in ICONSET:
            pixels = base * factor
            image = master.get(pixels) or draw_icon(pixels)
            suffix = "" if factor == 1 else "@2x"
            image.save(os.path.join(iconset, f"icon_{base}x{base}{suffix}.png"))
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", output], check=True)

    print(f"wrote {output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
