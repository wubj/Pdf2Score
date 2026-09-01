#!/usr/bin/env python3
"""Draw the 1200x630 link-preview images used by og:image.

    ./Tools/make_share_image.py     -> docs/share.png      (繁體中文)
                                       docs/share-en.png   (English)

Run with the project's venv python — Pillow lives there, and the system
python3 that `make guide` uses does not have it. The output is committed, so
rebuilding the guides never needs Pillow.

These are what Facebook, Threads, LINE, Discord and X show when someone pastes
a link to the guide. Without them the preview is a blank card, which in a feed
is indistinguishable from a broken link.

The artwork comes from make_icon.draw_icon so the icon here can never drift
from the one in the app bundle.
"""

from __future__ import annotations

import glob
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from PIL import Image, ImageDraw, ImageFont

from make_icon import draw_icon, vertical_gradient

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

WIDTH, HEIGHT = 1200, 630
TOP = (74, 108, 214, 255)
BOTTOM = (38, 58, 140, 255)

# San Francisco is a variable font; PingFang is a collection indexed by face.
SF = "/System/Library/Fonts/SFNS.ttf"
CJK_CANDIDATES = [
    # Sequoia keeps PingFang under AssetsV2, not the classic Fonts directory.
    *sorted(glob.glob("/System/Library/AssetsV2/**/PingFang.ttc", recursive=True)),
    "/System/Library/Fonts/Supplemental/STHeiti Medium.ttc",
    "/System/Library/Fonts/Hiragino Sans GB.ttc",
]
PINGFANG_TC = {"Regular": 2, "Medium": 6}

CARDS = [
    {
        "output": os.path.join("docs", "share.png"),
        "script": "cjk",
        "tagline": ["把 PDF 樂譜轉成", "MuseScore 打得開的檔案"],
        "features": "兩個辨識引擎 · 批次轉換 · 全程離線 · 免費開源",
        "url": "wubj.github.io/Pdf2Score",
    },
    {
        "output": os.path.join("docs", "share-en.png"),
        "script": "latin",
        "tagline": ["Turn PDF sheet music into", "files MuseScore can open"],
        "features": "Two engines · Batch conversion · Fully offline · Open source",
        "url": "wubj.github.io/Pdf2Score/en",
    },
]


def latin(size: int, weight: str) -> ImageFont.FreeTypeFont:
    font = ImageFont.truetype(SF, size)
    font.set_variation_by_name(weight)
    return font


def cjk(size: int, weight: str) -> ImageFont.FreeTypeFont:
    for path in CJK_CANDIDATES:
        try:
            index = PINGFANG_TC[weight] if path.endswith("PingFang.ttc") else 0
            return ImageFont.truetype(path, size, index=index)
        except OSError:
            continue
    raise SystemExit("error: no usable CJK font found")


def note_watermark(height: int) -> Image.Image:
    """The icon's quarter note, blown up as a faint background mark.

    Coordinates are the ones in make_icon.draw_icon's 1024 space, so the two
    shapes stay identical if either is ever adjusted.
    """
    box = (360, 276, 628, 524)
    scale = height / (box[3] - box[1])
    width = int((box[2] - box[0]) * scale)
    layer = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)

    def p(x: float, y: float) -> tuple[float, float]:
        return ((x - box[0]) * scale, (y - box[1]) * scale)

    ink = (255, 255, 255, 19)
    draw.ellipse([p(360, 430), p(492, 524)], fill=ink)
    draw.rectangle([p(468, 276), p(496, 478)], fill=ink)
    draw.polygon([p(496, 276), p(628, 340), p(628, 424), p(496, 360)], fill=ink)
    return layer


def build(card: dict) -> None:
    face = cjk if card["script"] == "cjk" else latin

    canvas = vertical_gradient(HEIGHT, TOP, BOTTOM).resize((WIDTH, HEIGHT))
    canvas = canvas.convert("RGBA")

    mark = note_watermark(452)
    canvas.alpha_composite(mark, (WIDTH - mark.width - 74, 104))

    icon = draw_icon(1024).resize((132, 132), Image.LANCZOS)
    canvas.alpha_composite(icon, (80, 74))

    draw = ImageDraw.Draw(canvas)
    draw.text((240, 140), "Pdf2Score", font=latin(76, "Bold"),
              fill=(255, 255, 255, 255), anchor="lm")

    tagline = face(52, "Medium")
    for index, line in enumerate(card["tagline"]):
        draw.text((80, 296 + index * 76), line, font=tagline,
                  fill=(236, 241, 255, 255), anchor="lm")

    draw.line([(80, 462), (272, 462)], fill=(255, 255, 255, 70), width=3)

    draw.text((80, 512), card["features"], font=face(29, "Regular"),
              fill=(174, 195, 245, 255), anchor="lm")
    draw.text((80, 562), card["url"], font=latin(28, "Medium"),
              fill=(139, 165, 228, 255), anchor="lm")

    output = os.path.join(ROOT, card["output"])
    canvas.convert("RGB").save(output, "PNG", optimize=True)
    print(f"wrote {card['output']} ({os.path.getsize(output) / 1024:.0f} KB)")


def main() -> int:
    for card in CARDS:
        build(card)
    return 0


if __name__ == "__main__":
    sys.exit(main())
