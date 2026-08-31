#!/usr/bin/env python3
"""End-to-end and unit checks for the Python side of Pdf2Score.

Run with the project's venv python:  make test
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PYTHON_DIR = os.path.join(ROOT, "Resources", "python")
SAMPLES = os.path.join(ROOT, "samples")
sys.path.insert(0, PYTHON_DIR)

from musicxml_merge import (  # noqa: E402
    MergeMismatch,
    ensure_title,
    measure_counts,
    merge_pages,
)
from mxl import write_mxl  # noqa: E402

failures: list[str] = []


def check(condition: bool, label: str) -> None:
    print(f"{'PASS' if condition else 'FAIL'}  {label}")
    if not condition:
        failures.append(label)


def synthetic_page(part_ids: list[str], measures: int) -> str:
    parts = "".join(
        f'<score-part id="{pid}"><part-name>P</part-name></score-part>' for pid in part_ids
    )
    bodies = ""
    for pid in part_ids:
        measure_xml = "".join(
            f'<measure number="{i}"><note><rest/><duration>4</duration></note></measure>'
            for i in range(1, measures + 1)
        )
        bodies += f'<part id="{pid}">{measure_xml}</part>'
    return (
        '<?xml version="1.0" encoding="UTF-8"?>'
        f'<score-partwise version="4.0"><part-list>{parts}</part-list>{bodies}</score-partwise>'
    )


def write(path: str, text: str) -> str:
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)
    return path


def test_merge() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        page1 = write(os.path.join(tmp, "p1.musicxml"), synthetic_page(["P1"], 8))
        page2 = write(os.path.join(tmp, "p2.musicxml"), synthetic_page(["P1"], 5))
        merged = os.path.join(tmp, "merged.musicxml")
        merge_pages([page1, page2], merged, "Fallback Title")

        check(measure_counts(merged) == [13], "merge: 8 + 5 measures -> 13")

        root = ET.parse(merged).getroot()
        numbers = [m.get("number") for m in root.find("part").findall("measure")]
        check(
            numbers == [str(i) for i in range(1, 14)],
            "merge: measure numbers are contiguous 1..13",
        )
        title = root.findtext("work/work-title")
        check(title == "Fallback Title", "merge: blank title falls back to the file name")

        # Two parts on both pages should merge the same way.
        two1 = write(os.path.join(tmp, "t1.musicxml"), synthetic_page(["P1", "P2"], 4))
        two2 = write(os.path.join(tmp, "t2.musicxml"), synthetic_page(["P1", "P2"], 3))
        merged2 = os.path.join(tmp, "merged2.musicxml")
        merge_pages([two1, two2], merged2, "x")
        check(measure_counts(merged2) == [7, 7], "merge: two parts merge independently")

        # Mismatched part layout must refuse rather than produce a wrong score.
        odd = write(os.path.join(tmp, "odd.musicxml"), synthetic_page(["P1", "P2"], 4))
        try:
            merge_pages([page1, odd], os.path.join(tmp, "bad.musicxml"), "x")
            check(False, "merge: mismatched part layout raises MergeMismatch")
        except MergeMismatch:
            check(True, "merge: mismatched part layout raises MergeMismatch")


def test_mxl() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        score = write(os.path.join(tmp, "song.musicxml"), synthetic_page(["P1"], 2))
        packed = os.path.join(tmp, "song.mxl")
        write_mxl(score, packed)

        with zipfile.ZipFile(packed) as archive:
            names = archive.namelist()
            container = archive.read("META-INF/container.xml").decode()
            mimetype = archive.read("mimetype").decode()
        check(names[0] == "mimetype", "mxl: mimetype is the first entry")
        check(mimetype == "application/vnd.recordare.musicxml", "mxl: mimetype content")
        check("song.musicxml" in container, "mxl: container points at the score")

        # The archive must be named after the output, not after the temp file
        # the worker actually packed from.
        renamed = os.path.join(tmp, "renamed.mxl")
        write_mxl(score, renamed, inner_name="Nocturne.musicxml")
        with zipfile.ZipFile(renamed) as archive:
            check(
                "Nocturne.musicxml" in archive.namelist()
                and "Nocturne.musicxml" in archive.read("META-INF/container.xml").decode(),
                "mxl: inner_name overrides the source file name",
            )


def title_of(path: str) -> str | None:
    return ET.parse(path).getroot().findtext("work/work-title")


def test_title_fallback() -> None:
    """Title detection is off, so the file name has to fill the gap."""
    with tempfile.TemporaryDirectory() as tmp:
        blank = write(os.path.join(tmp, "s.musicxml"), synthetic_page(["P1"], 2))
        ensure_title(blank, "Nocturne")
        check(title_of(blank) == "Nocturne", "title: blank score gets the file name")

        kept = write(
            os.path.join(tmp, "k.musicxml"),
            synthetic_page(["P1"], 2).replace(
                "<part-list>", "<work><work-title>Real Title</work-title></work><part-list>"
            ),
        )
        ensure_title(kept, "Nocturne")
        check(title_of(kept) == "Real Title", "title: an existing title is left alone")


def unpack(mxl_path: str, out_dir: str, label: str) -> str | None:
    """Extract the score from an .mxl so its contents can be inspected."""
    if not os.path.exists(mxl_path):
        return None
    with zipfile.ZipFile(mxl_path) as archive:
        # homr names the score .musicxml, Audiveris names it .xml.
        scores = [
            n for n in archive.namelist()
            if n.endswith((".musicxml", ".xml")) and not n.startswith("META-INF")
        ]
        if not scores:
            return None
        target = os.path.join(out_dir, f"_unpacked_{label}.musicxml")
        with open(target, "wb") as handle:
            handle.write(archive.read(scores[0]))
    return target


def test_worker_end_to_end() -> None:
    pdfs = [
        os.path.join(SAMPLES, "one_page.pdf"),
        os.path.join(SAMPLES, "multi_page.pdf"),
    ]
    missing = [p for p in pdfs if not os.path.exists(p)]
    if missing:
        print(f"SKIP  worker end-to-end (missing samples: {missing})")
        return

    with tempfile.TemporaryDirectory() as out_dir:
        spec = {
            "jobs": [{"id": f"J{i}", "pdf": p} for i, p in enumerate(pdfs)],
            "options": {"outputDir": out_dir, "dpi": 300, "merge": True},
        }
        result = subprocess.run(
            [sys.executable, "-u", os.path.join(PYTHON_DIR, "worker.py")],
            input=json.dumps(spec),
            capture_output=True,
            text=True,
        )
        events = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
        kinds = [event["event"] for event in events]

        check(result.returncode == 0, "worker: exits cleanly")
        check(
            kinds[:2] == ["starting", "ready"] and kinds[-1] == "all_done",
            "worker: starting/ready/all_done bookend",
        )
        # "starting" must be emitted before the heavy imports, otherwise the app
        # cannot tell a cold start apart from a hang.
        check(
            result.stdout.splitlines()[0].strip() == '{"event": "starting"}',
            "worker: starting is the very first line",
        )
        check(kinds.count("file_done") == 2, "worker: both files reported done")
        check("file_error" not in kinds, "worker: no file errors")

        one_mxl = os.path.join(out_dir, "one_page.mxl")
        multi_mxl = os.path.join(out_dir, "multi_page.mxl")
        check(os.path.exists(one_mxl) and os.path.exists(multi_mxl), "worker: mxl written for both")
        check(
            not any(name.endswith(".musicxml") for name in os.listdir(out_dir)),
            "worker: no loose .musicxml by default",
        )
        for event in events:
            if event["event"] == "file_done":
                check(
                    all(path.endswith(".mxl") for path in event["outputs"]),
                    f"worker: {event['id']} reports only .mxl outputs",
                )

        # Unpack for the content checks below.
        one = unpack(one_mxl, out_dir, "one")
        multi = unpack(multi_mxl, out_dir, "multi")

        if one and multi:
            one_count = measure_counts(one)[0]
            multi_count = measure_counts(multi)[0]
            check(one_count > 0, f"worker: single page recognised ({one_count} measures)")
            check(
                multi_count > one_count,
                f"worker: page 2 content is present ({multi_count} vs {one_count} measures)",
            )
            check(
                title_of(one) == "one_page",
                f"worker: single-page title falls back to the file name ({title_of(one)!r})",
            )
            root = ET.parse(multi).getroot()
            numbers = [m.get("number") for m in root.find("part").findall("measure")]
            check(
                numbers == [str(i) for i in range(1, multi_count + 1)],
                "worker: merged measure numbers are contiguous",
            )


def find_audiveris() -> str | None:
    """The bundled engine, from a built app or straight from build/."""
    import platform

    candidates = [
        os.path.join(
            ROOT, "build", platform.machine(), "Pdf2Score.app", "Contents", "Resources",
            "Audiveris.app", "Contents", "MacOS", "Audiveris",
        ),
        os.path.join(
            ROOT, "build", f"audiveris-{platform.machine()}",
            "Audiveris.app", "Contents", "MacOS", "Audiveris",
        ),
    ]
    return next((c for c in candidates if os.path.exists(c)), None)


def test_audiveris_engine() -> None:
    launcher = find_audiveris()
    pdf = os.path.join(SAMPLES, "one_page.pdf")
    if not launcher or not os.path.exists(pdf):
        print("SKIP  audiveris engine (not built yet)")
        return

    with tempfile.TemporaryDirectory() as out_dir:
        spec = {
            "jobs": [{"id": "A", "pdf": pdf}],
            "options": {
                "engine": "audiveris",
                "audiverisPath": launcher,
                "outputDir": out_dir,
                "merge": True,
            },
        }
        result = subprocess.run(
            [sys.executable, "-u", os.path.join(PYTHON_DIR, "worker.py")],
            input=json.dumps(spec),
            capture_output=True,
            text=True,
        )
        events = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
        kinds = [event["event"] for event in events]

        check("file_done" in kinds and "file_error" not in kinds, "audiveris: file converted")
        produced = sorted(os.listdir(out_dir))
        check(produced == ["one_page.mxl"], f"audiveris: only the .mxl is kept ({produced})")
        # Audiveris drops a .omr project file and a .log beside its output; those
        # belong in the temp folder, not in the user's.
        check(
            not any(name.endswith((".omr", ".log")) for name in produced),
            "audiveris: no .omr/.log left behind",
        )
        if "one_page.mxl" in produced:
            score = unpack(os.path.join(out_dir, "one_page.mxl"), out_dir, "aud")
            if score:
                counts = measure_counts(score)
                check(counts == [16], f"audiveris: 16 measures recognised (got {counts})")


def test_keep_musicxml() -> None:
    """The uncompressed .musicxml option has to work on both engines."""
    launcher = find_audiveris()
    pdf = os.path.join(SAMPLES, "one_page.pdf")
    if not os.path.exists(pdf):
        print("SKIP  keepMusicXml (missing sample)")
        return

    engines = [("homr", None)]
    if launcher:
        engines.append(("audiveris", launcher))

    for engine, path in engines:
        with tempfile.TemporaryDirectory() as out_dir:
            spec = {
                "jobs": [{"id": "K", "pdf": pdf}],
                "options": {
                    "engine": engine,
                    "audiverisPath": path,
                    "outputDir": out_dir,
                    "keepMusicXml": True,
                },
            }
            subprocess.run(
                [sys.executable, "-u", os.path.join(PYTHON_DIR, "worker.py")],
                input=json.dumps(spec),
                capture_output=True,
                text=True,
            )
            produced = sorted(os.listdir(out_dir))
            check(
                produced == ["one_page.musicxml", "one_page.mxl"],
                f"keepMusicXml[{engine}]: both files written ({produced})",
            )
            plain = os.path.join(out_dir, "one_page.musicxml")
            if os.path.exists(plain):
                check(
                    measure_counts(plain) == [16],
                    f"keepMusicXml[{engine}]: the plain XML parses and matches",
                )


def main() -> int:
    test_merge()
    test_title_fallback()
    test_mxl()
    test_worker_end_to_end()
    test_audiveris_engine()
    test_keep_musicxml()
    print()
    if failures:
        print(f"{len(failures)} check(s) failed:")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
