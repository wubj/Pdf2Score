#!/usr/bin/env python3
"""Build the user guide from docs/src/guide.html into a standalone page.

    ./Tools/build_guide.py            -> docs/index.html

Two things happen here that the source cannot do on its own:

* The app icon is inlined as a data: URI, so the finished page is a single file
  that works from a disk image with no network.
* `var(--token)` is folded out of SVG presentation attributes into `style="..."`.
  CSS custom properties are not valid in presentation attributes — browsers
  ignore them and the illustrations render in default black — so the source
  keeps the readable form and this step rewrites it.
"""

from __future__ import annotations

import base64
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "docs", "src", "guide.html")
ICON = os.path.join(ROOT, "docs", "icon", "AppIcon-256.png")
OUTPUT = os.path.join(ROOT, "docs", "index.html")

DESCRIPTION = "Pdf2Score 的安裝與使用說明：把 PDF 樂譜轉成 MuseScore 打得開的檔案。"

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


def main() -> int:
    with open(SOURCE, encoding="utf-8") as handle:
        markup = handle.read()

    with open(ICON, "rb") as handle:
        icon = base64.b64encode(handle.read()).decode("ascii")

    body = fold_css_variables(markup).replace("ICON_B64", icon).rstrip()

    leftovers = re.findall(r'\s(?!style=)[\w-]+="var\(--', body)
    if leftovers:
        print(f"error: {len(leftovers)} var() attributes were not folded", file=sys.stderr)
        return 1
    if "ICON_B64" in body:
        print("error: the icon placeholder was not replaced", file=sys.stderr)
        return 1

    head_end = body.index("</style>") + len("</style>")
    page = (
        '<!doctype html>\n<html lang="zh-Hant">\n<head>\n'
        '<meta charset="utf-8">\n'
        '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
        f'<meta name="description" content="{DESCRIPTION}">\n'
        + body[:head_end]
        + "\n</head>\n<body>\n"
        + body[head_end:].lstrip()
        + "\n</body>\n</html>\n"
    )

    with open(OUTPUT, "w", encoding="utf-8") as handle:
        handle.write(page)

    print(f"wrote {os.path.relpath(OUTPUT, ROOT)} ({len(page) / 1024:.0f} KB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
