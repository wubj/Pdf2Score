"""Pack a .musicxml file into the compressed .mxl container format.

Layout per the MusicXML spec: an uncompressed "mimetype" entry first, then
META-INF/container.xml pointing at the score, then the score itself.
"""

from __future__ import annotations

import os
import zipfile

MIMETYPE = "application/vnd.recordare.musicxml"

_CONTAINER = """<?xml version="1.0" encoding="UTF-8"?>
<container>
  <rootfiles>
    <rootfile full-path="{score}" media-type="application/vnd.recordare.musicxml+xml"/>
  </rootfiles>
</container>
"""


def write_mxl(musicxml_path: str, mxl_path: str, inner_name: str | None = None) -> None:
    """`inner_name` names the score inside the archive, which matters when the
    source is a temporary file that the user never sees."""
    score_name = inner_name or os.path.basename(musicxml_path)
    with open(musicxml_path, "rb") as handle:
        score = handle.read()

    with zipfile.ZipFile(mxl_path, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(
            zipfile.ZipInfo("mimetype"), MIMETYPE, compress_type=zipfile.ZIP_STORED
        )
        archive.writestr("META-INF/container.xml", _CONTAINER.format(score=score_name))
        archive.writestr(score_name, score)
