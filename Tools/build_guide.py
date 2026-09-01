#!/usr/bin/env python3
"""Build the user guides from docs/src/ into standalone pages.

    ./Tools/build_guide.py     -> docs/index.html      (繁體中文)
                                  docs/en/index.html   (English)

Each guide is one self-contained file: the stylesheet and the app icon are
inlined, so a copy on a disk image works with no network and nothing to resolve.

Two things happen here that the sources cannot do themselves:

* The icon is embedded as a data: URI, and used as the favicon.
* Open Graph tags are generated, pointing at the social cards in docs/.
* `var(--token)` is folded out of SVG presentation attributes into `style="..."`.
  CSS custom properties are not valid in presentation attributes — browsers
  ignore them and the illustrations render in default black — so the sources
  keep the readable form and this step rewrites it.
"""

from __future__ import annotations

import base64
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE_DIR = os.path.join(ROOT, "docs", "src")
ICON = os.path.join(ROOT, "docs", "icon", "AppIcon-256.png")
SITE = "https://wubj.github.io/Pdf2Score/"
STYLESHEET = os.path.join(SOURCE_DIR, "guide.css")

FONTS = (
    "https://fonts.googleapis.com/css2?family=Fraunces:opsz,wght@9..144,400;9..144,600"
    "&family=JetBrains+Mono:wght@400;500&family=Noto+Sans+TC:wght@400;500;700"
    "&family=Noto+Serif+TC:wght@600;700&family=Source+Sans+3:ital,wght@0,400;0,600;1,400"
    "&display=swap"
)

GUIDES = [
    {
        "source": "guide.zh-Hant.html",
        "output": os.path.join("docs", "index.html"),
        "lang": "zh-Hant",
        "title": "Pdf2Score 使用指南",
        "description": "Pdf2Score 的安裝與使用說明：把 PDF 樂譜轉成 MuseScore 打得開的檔案。",
        "url": SITE,
        "locale": "zh_TW",
        "share": "share.png",
        "share_alt": "Pdf2Score：把 PDF 樂譜轉成 MuseScore 打得開的檔案",
    },
    {
        "source": "guide.en.html",
        "output": os.path.join("docs", "en", "index.html"),
        "lang": "en",
        "title": "Pdf2Score User Guide",
        "description": "How to install and use Pdf2Score: turn PDF sheet music into files MuseScore can open.",
        "url": SITE + "en/",
        "locale": "en_US",
        "share": "share-en.png",
        "share_alt": "Pdf2Score: turn PDF sheet music into files MuseScore can open",
    },
]

TAG = re.compile(r"<(\w[\w-]*)((?:\s+[\w:-]+=\"[^\"]*\")*)\s*(/?)>")
VAR_ATTR = re.compile(r'\s+([\w-]+)="(var\(--[^"]+\))"')


def fold_css_variables(markup: str) -> str:
    def rewrite(match: re.Match[str]) -> str:
        name, attributes, slash = match.group(1), match.group(2), match.group(3)
        found = VAR_ATTR.findall(attributes)
        if not found:
            return match.group(0)
        attributes = VAR_ATTR.sub("", attributes)
        declarations = "; ".join(f"{prop}: {value}" for prop, value in found)
        existing = re.search(r'\s+style="([^"]*)"', attributes)
        if existing:
            merged = existing.group(1).rstrip("; ") + "; " + declarations
            attributes = (
                attributes[: existing.start()]
                + f' style="{merged}"'
                + attributes[existing.end() :]
            )
        else:
            attributes += f' style="{declarations}"'
        return f"<{name}{attributes}{slash}>"

    return TAG.sub(rewrite, markup)


def build(guide: dict[str, str], css: str, icon: str) -> bool:
    with open(os.path.join(SOURCE_DIR, guide["source"]), encoding="utf-8") as handle:
        body = fold_css_variables(handle.read()).replace("ICON_B64", icon).rstrip()

    leftovers = re.findall(r'\s(?!style=)[\w-]+="var\(--', body)
    if leftovers:
        print(f"error: {guide['source']}: {len(leftovers)} var() attributes not folded",
              file=sys.stderr)
        return False
    if "ICON_B64" in body:
        print(f"error: {guide['source']}: the icon placeholder was not replaced",
              file=sys.stderr)
        return False

    # og:image is fetched by Facebook, Threads, LINE and X from the live site,
    # so a missing file means a blank preview card that nothing here would
    # otherwise catch — the page itself renders fine without it.
    if not os.path.exists(os.path.join(ROOT, "docs", guide["share"])):
        print(f"error: {guide['share']} is missing — run Tools/make_share_image.py",
              file=sys.stderr)
        return False

    share = SITE + guide["share"]
    social = "".join(
        f'<meta {kind}="{name}" content="{value}">\n'
        for kind, name, value in (
            ("property", "og:type", "website"),
            ("property", "og:site_name", "Pdf2Score"),
            ("property", "og:locale", guide["locale"]),
            ("property", "og:title", guide["title"]),
            ("property", "og:description", guide["description"]),
            ("property", "og:url", guide["url"]),
            ("property", "og:image", share),
            ("property", "og:image:width", "1200"),
            ("property", "og:image:height", "630"),
            ("property", "og:image:alt", guide["share_alt"]),
            ("name", "twitter:card", "summary_large_image"),
            ("name", "twitter:title", guide["title"]),
            ("name", "twitter:description", guide["description"]),
            ("name", "twitter:image", share),
        )
    )

    page = (
        f'<!doctype html>\n<html lang="{guide["lang"]}">\n<head>\n'
        '<meta charset="utf-8">\n'
        '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
        f'<meta name="description" content="{guide["description"]}">\n'
        f'<title>{guide["title"]}</title>\n'
        f'<link rel="canonical" href="{guide["url"]}">\n'
        # Inlined rather than linked: the copy that ships on the disk image has
        # no docs/icon/ next to it.
        f'<link rel="icon" type="image/png" href="data:image/png;base64,{icon}">\n'
        + social +
        '<link rel="preconnect" href="https://fonts.googleapis.com">\n'
        '<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>\n'
        f'<link rel="stylesheet" href="{FONTS}">\n'
        f"<style>\n{css}\n</style>\n"
        "</head>\n<body>\n"
        + body
        + "\n</body>\n</html>\n"
    )

    output = os.path.join(ROOT, guide["output"])
    os.makedirs(os.path.dirname(output), exist_ok=True)
    with open(output, "w", encoding="utf-8") as handle:
        handle.write(page)

    print(f"wrote {guide['output']} ({len(page) / 1024:.0f} KB, {guide['lang']})")
    return True


def main() -> int:
    with open(STYLESHEET, encoding="utf-8") as handle:
        css = handle.read().strip("\n")
    with open(ICON, "rb") as handle:
        icon = base64.b64encode(handle.read()).decode("ascii")

    return 0 if all(build(guide, css, icon) for guide in GUIDES) else 1


if __name__ == "__main__":
    sys.exit(main())
