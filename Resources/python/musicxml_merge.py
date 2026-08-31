"""Merge the per-page MusicXML files of one PDF into a single score.

homr recognises one image at a time, so a multi-page PDF comes back as one
MusicXML per page. Each page repeats the full score header (part-list, clef,
key, time), so merging is a matter of appending the later pages' measures to
the first page's parts and renumbering — repeated <attributes> mid-score are
legal MusicXML and MuseScore handles them fine.
"""

from __future__ import annotations

import xml.etree.ElementTree as ET


class MergeMismatch(Exception):
    """The pages don't line up well enough to be merged safely."""


def _part_ids(root: ET.Element) -> list[str]:
    return [p.get("id") or "" for p in root.findall("part")]


def _measure_counts(root: ET.Element) -> list[int]:
    return [len(p.findall("measure")) for p in root.findall("part")]


def merge_pages(page_files: list[str], out_path: str, fallback_title: str) -> None:
    """Merge `page_files` in order into `out_path`.

    Raises MergeMismatch when the pages disagree on their part structure, so
    the caller can fall back to writing the pages out separately.
    """
    if not page_files:
        raise MergeMismatch("no pages to merge")

    roots = [ET.parse(f).getroot() for f in page_files]
    base = roots[0]
    base_ids = _part_ids(base)
    if not base_ids:
        raise MergeMismatch("first page has no parts")

    for path, root in zip(page_files[1:], roots[1:], strict=True):
        ids = _part_ids(root)
        if ids != base_ids:
            raise MergeMismatch(
                f"part layout differs: page 1 has {base_ids}, {path} has {ids}"
            )

    for root in roots[1:]:
        for part_id in base_ids:
            base_part = base.find(f"part[@id='{part_id}']")
            next_part = root.find(f"part[@id='{part_id}']")
            if base_part is None or next_part is None:
                raise MergeMismatch(f"part {part_id} missing on one of the pages")
            for measure in next_part.findall("measure"):
                base_part.append(measure)

    for part in base.findall("part"):
        for number, measure in enumerate(part.findall("measure"), start=1):
            measure.set("number", str(number))

    _set_title_if_blank(base, fallback_title)

    ET.indent(base, space="  ")
    ET.ElementTree(base).write(out_path, encoding="UTF-8", xml_declaration=True)


def ensure_title(path: str, fallback_title: str) -> None:
    """Give a score a title when it has none.

    homr's own title comes from running OCR across the top of the page, which we
    switch off: it was wrong on every score we tried ("Tcst One T age" for "Test
    One Page") and cost an OCR pass per page. The file name is both more
    accurate and free.
    """
    tree = ET.parse(path)
    root = tree.getroot()
    _set_title_if_blank(root, fallback_title)
    ET.indent(root, space="  ")
    tree.write(path, encoding="UTF-8", xml_declaration=True)


def measure_counts(path: str) -> list[int]:
    """Measures per part — used by the merge verification test."""
    return _measure_counts(ET.parse(path).getroot())


def _set_title_if_blank(root: ET.Element, fallback_title: str) -> None:
    work = root.find("work")
    if work is None:
        work = ET.Element("work")
        root.insert(0, work)
    title = work.find("work-title")
    if title is None:
        title = ET.SubElement(work, "work-title")
    if not (title.text or "").strip():
        title.text = fallback_title
