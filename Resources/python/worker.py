#!/usr/bin/env python3
"""Batch OMR worker: PDF sheet music -> MusicXML, driven by the Pdf2Score app.

Reads one JSON job spec from stdin, streams NDJSON progress events, and writes
the resulting .musicxml (and optionally .mxl) files.

Why a single long-lived worker for the whole batch: homr loads ~130 MB of ONNX
models, so paying that cost once and reusing it across every page of every file
is dramatically faster than spawning a process per file.

    {"jobs":    [{"id": "A1", "pdf": "/path/to/score.pdf"}],
     "options": {"engine": "homr", "audiverisPath": null,
                 "outputDir": null, "dpi": 300, "merge": true, "keepMusicXml": false,
                 "coremlEncoder": false, "keepPreviews": false,
                 "largePage": false, "metronome": null, "tempo": null}}

Two recognition engines are available and they fail in different ways, so
"try the other one" is the most useful thing a user can do with a bad result:

    homr       transformer-based, runs in this process, one page at a time
    audiveris  a separate Java application, reads the PDF itself and writes
               the .mxl directly, so the page splitting and merging below are
               skipped entirely for that path

Events (one JSON object per line on the event channel):
    {"event":"starting"}   emitted before the heavy imports, which on a cold
                           start can take a minute while macOS verifies the
                           bundle's dylibs and Python compiles its bytecode
    {"event":"ready"}
    {"event":"file_start","id":..,"pages":N,"name":..}
    {"event":"page_start","id":..,"page":i}
    {"event":"page_done","id":..,"page":i}
    {"event":"page_error","id":..,"page":i,"message":..}
    {"event":"file_done","id":..,"outputs":[..],"merged":bool,"warning":str|null}
    {"event":"file_error","id":..,"message":..}
    {"event":"all_done"}
"""

from __future__ import annotations

import concurrent.futures as futures
import glob
import json
import os
import platform
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import traceback
import zipfile
from typing import Any

# homr, onnxruntime and rapidocr all log to stdout. Claim a private duplicate of
# fd 1 for the event stream and point the real fd 1 at stderr *before* importing
# any of them, so nothing can interleave log noise into our NDJSON.
_EVENT_FD = os.dup(1)
os.dup2(2, 1)
sys.stdout = sys.stderr


def emit(**event: Any) -> None:
    line = json.dumps(event, ensure_ascii=False) + "\n"
    os.write(_EVENT_FD, line.encode("utf-8"))


# Say hello before importing anything heavy. A cold start spends up to a minute
# in the imports below, and without this the app cannot tell "still loading"
# apart from "nothing is happening".
emit(event="starting")

os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "3")

# The CoreML execution provider caches its compiled models next to the .onnx
# file, which for a distributable build means inside the (possibly read-only)
# app bundle. Point it at the user's cache directory instead, so the compile
# happens once and survives, wherever the app itself lives.
_COREML_CACHE = os.path.expanduser("~/Library/Caches/Pdf2Score/coreml")
os.makedirs(_COREML_CACHE, exist_ok=True)
os.environ.setdefault("HOMR_COREML_MODEL_CACHE_DIR", _COREML_CACHE)

import cv2  # noqa: E402
import numpy as np  # noqa: E402
import pypdfium2 as pdfium  # noqa: E402

from homr.autocrop import autocrop  # noqa: E402
from homr.main import ProcessingConfig, process_image  # noqa: E402
from homr.music_xml_generator import XmlGeneratorArguments  # noqa: E402
from homr.onnx_providers import coreml_available, cuda_available  # noqa: E402
import homr.main as homr_main  # noqa: E402


def _skip_title_detection(_debug: Any, _staff: Any) -> "futures.Future[str]":
    """homr runs OCR over the top of every page to guess the title.

    It was wrong on every score we tested, and the file name — which the title
    fixup falls back to — is both more accurate and free. Skipping it also drops
    the OCR model files from the bundle entirely.
    """
    result: futures.Future[str] = futures.Future()
    result.set_result("")
    return result


homr_main.detect_title = _skip_title_detection

from musicxml_merge import MergeMismatch, ensure_title, merge_pages  # noqa: E402
from mxl import write_mxl  # noqa: E402


def log(*parts: Any) -> None:
    print(*parts, file=sys.stderr, flush=True)


def render_pages(pdf_path: str, out_dir: str, dpi: int) -> list[str]:
    """Render every page to an autocropped PNG, returning the paths in order."""
    scale = dpi / 72.0
    paths = []
    pdf = pdfium.PdfDocument(pdf_path)
    try:
        for index, page in enumerate(pdf):
            bitmap = page.render(scale=scale)
            rgb = np.array(bitmap.to_pil().convert("RGB"))
            bgr = cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)
            path = os.path.join(out_dir, f"page_{index + 1:03d}.png")
            cv2.imwrite(path, autocrop(bgr))
            paths.append(path)
    finally:
        pdf.close()
    return paths


def unique_path(path: str) -> str:
    """Never silently clobber a file the user may have edited already."""
    if not os.path.exists(path):
        return path
    stem, ext = os.path.splitext(path)
    counter = 2
    while os.path.exists(f"{stem} ({counter}){ext}"):
        counter += 1
    return f"{stem} ({counter}){ext}"


def write_outputs(source_xml: str, target_stem: str, keep_musicxml: bool) -> list[str]:
    """Write the finished score as .mxl, plus the plain .musicxml on request.

    `target_stem` is the output path without an extension. `source_xml` is a
    temporary file, so the name stored inside the archive comes from the stem
    rather than from the temporary file's name.
    """
    outputs: list[str] = []
    inner_name = os.path.basename(target_stem) + ".musicxml"

    mxl_path = unique_path(target_stem + ".mxl")
    write_mxl(source_xml, mxl_path, inner_name=inner_name)
    outputs.append(mxl_path)

    if keep_musicxml:
        target = unique_path(target_stem + ".musicxml")
        with open(source_xml, "rb") as src, open(target, "wb") as dst:
            dst.write(src.read())
        outputs.append(target)

    return outputs


def process_job(
    job: dict[str, Any],
    options: dict[str, Any],
    config: ProcessingConfig,
    xml_args: XmlGeneratorArguments,
) -> None:
    job_id = job["id"]
    pdf_path = job["pdf"]
    stem = os.path.splitext(os.path.basename(pdf_path))[0]
    out_dir = options.get("outputDir") or os.path.dirname(os.path.abspath(pdf_path))
    os.makedirs(out_dir, exist_ok=True)

    if options.get("engine") == "audiveris":
        process_job_audiveris(job_id, pdf_path, stem, out_dir, options)
        return

    work_dir = tempfile.mkdtemp(prefix="pdf2score-")
    try:
        page_images = render_pages(pdf_path, work_dir, int(options.get("dpi", 300)))
        emit(event="file_start", id=job_id, name=os.path.basename(pdf_path), pages=len(page_images))
        if not page_images:
            raise ValueError("PDF 沒有任何頁面")

        page_xmls: list[str] = []
        for number, image in enumerate(page_images, start=1):
            emit(event="page_start", id=job_id, page=number)
            started = time.time()
            try:
                process_image(image, config, xml_args)
            except Exception as error:  # a bad page must not sink the whole file
                log(f"page {number} failed: {error}")
                emit(event="page_error", id=job_id, page=number, message=str(error))
                continue
            page_xmls.append(os.path.splitext(image)[0] + ".musicxml")
            log(f"page {number} took {time.time() - started:.1f}s")
            emit(event="page_done", id=job_id, page=number)

        if not page_xmls:
            raise ValueError("所有頁面都辨識失敗（可能不是樂譜，或掃描品質太低）")

        if options.get("keepPreviews"):
            _copy_previews(page_images, out_dir, stem)

        outputs: list[str] = []
        warning: str | None = None
        merged = False

        if options.get("merge", True) and len(page_xmls) > 1:
            merged_path = os.path.join(work_dir, "merged.musicxml")
            try:
                merge_pages(page_xmls, merged_path, stem)
                merged = True
            except MergeMismatch as mismatch:
                warning = f"無法合併分頁，已改為分頁輸出：{mismatch}"
                log(warning)
        elif len(page_xmls) == 1:
            merged_path = page_xmls[0]
            ensure_title(merged_path, stem)
            merged = True

        keep_musicxml = bool(options.get("keepMusicXml", False))
        if merged:
            outputs = write_outputs(merged_path, os.path.join(out_dir, stem), keep_musicxml)
        else:
            for number, page_xml in enumerate(page_xmls, start=1):
                outputs += write_outputs(
                    page_xml, os.path.join(out_dir, f"{stem}_p{number}"), keep_musicxml
                )

        if len(page_xmls) < len(page_images):
            skipped = len(page_images) - len(page_xmls)
            note = f"有 {skipped} 頁辨識失敗，已略過"
            warning = f"{warning}；{note}" if warning else note

        emit(event="file_done", id=job_id, outputs=outputs, merged=merged, warning=warning)
    finally:
        _rmtree(work_dir)


# Audiveris logs one of these as each sheet of the book finishes.
_STUB_DONE = re.compile(r"End of Stub#(\d+)")


def process_job_audiveris(
    job_id: str, pdf_path: str, stem: str, out_dir: str, options: dict[str, Any]
) -> None:
    """Hand the whole PDF to Audiveris and collect the .mxl it writes.

    Audiveris reads PDFs itself and treats a multi-page file as one book, so
    there is nothing here to split or merge. It also drops a .omr project file
    and a .log beside its output, which is why it is pointed at a temp folder
    and only the .mxl is moved into place.
    """
    launcher = options.get("audiverisPath")
    if not launcher or not os.path.exists(launcher):
        raise ValueError("找不到 Audiveris 辨識引擎，App 內容可能不完整")

    page_count = count_pdf_pages(pdf_path)
    emit(event="file_start", id=job_id, name=os.path.basename(pdf_path), pages=page_count)

    work_dir = tempfile.mkdtemp(prefix="pdf2score-aud-")
    try:
        command = [launcher, "-batch", "-export", "-output", work_dir, "--", pdf_path]
        log("running " + " ".join(command))
        started = time.time()
        process = subprocess.Popen(
            command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1
        )
        assert process.stdout is not None  # noqa: S101
        current = 0
        for line in process.stdout:
            log(line.rstrip())
            match = _STUB_DONE.search(line)
            if match:
                finished = int(match.group(1))
                while current < finished:
                    current += 1
                    emit(event="page_start", id=job_id, page=current)
                    emit(event="page_done", id=job_id, page=current)
        code = process.wait()
        log(f"audiveris finished in {time.time() - started:.1f}s (exit {code})")

        produced = glob.glob(os.path.join(work_dir, "*.mxl"))
        if code != 0 or not produced:
            raise ValueError(
                "Audiveris 無法辨識這份 PDF"
                + (f"（結束代碼 {code}）" if code != 0 else "，沒有產生任何樂譜")
            )

        target = unique_path(os.path.join(out_dir, stem + ".mxl"))
        shutil.copyfile(produced[0], target)
        outputs = [target]

        if options.get("keepMusicXml"):
            outputs.append(extract_musicxml(target))

        emit(event="file_done", id=job_id, outputs=outputs, merged=True, warning=None)
    finally:
        _rmtree(work_dir)


def count_pdf_pages(pdf_path: str) -> int:
    pdf = pdfium.PdfDocument(pdf_path)
    try:
        return len(pdf)
    finally:
        pdf.close()


def extract_musicxml(mxl_path: str) -> str:
    """Unpack the score from a .mxl so the plain XML sits beside it."""
    target = unique_path(os.path.splitext(mxl_path)[0] + ".musicxml")
    with zipfile.ZipFile(mxl_path) as archive:
        names = [
            name
            for name in archive.namelist()
            if name.endswith((".musicxml", ".xml")) and not name.startswith("META-INF")
        ]
        with open(target, "wb") as handle:
            handle.write(archive.read(names[0]))
    return target


def _copy_previews(page_images: list[str], out_dir: str, stem: str) -> None:
    for number, image in enumerate(page_images, start=1):
        teaser = os.path.splitext(image)[0] + "_teaser.png"
        if os.path.exists(teaser):
            target = unique_path(os.path.join(out_dir, f"{stem}_p{number}_teaser.png"))
            with open(teaser, "rb") as src, open(target, "wb") as dst:
                dst.write(src.read())


def _rmtree(path: str) -> None:
    shutil.rmtree(path, ignore_errors=True)


def build_config(options: dict[str, Any]) -> tuple[ProcessingConfig, XmlGeneratorArguments]:
    """Mirror homr's own CLI device selection (homr.main.main, v0.7.0).

    One deliberate departure: on Intel Macs we stay on the CPU even though
    onnxruntime lists the CoreML provider. CoreML on Intel has no Neural Engine
    behind it, so there is little to gain, and a provider that fails to
    initialise would take the whole conversion down on a machine the user
    cannot debug. The CPU path is the one we can stand behind everywhere.
    """
    is_intel = platform.machine() == "x86_64"
    cuda = cuda_available()
    coreml = coreml_available() and not is_intel
    transformer_use_gpu = cuda
    segnet_use_gpu = cuda or coreml
    # The CoreML encoder only applies when the transformer isn't already on CUDA.
    coreml_encoder = bool(options.get("coremlEncoder")) and not transformer_use_gpu and coreml
    log(
        f"devices: arch={platform.machine()} cuda={cuda} "
        f"coreml={coreml} coreml_encoder={coreml_encoder}"
    )

    config = ProcessingConfig(
        False,  # enable_debug
        False,  # enable_cache
        False,  # write_staff_positions
        False,  # read_staff_positions
        -1,  # selected_staff
        transformer_use_gpu,
        segnet_use_gpu,
        coreml_encoder,
    )
    xml_args = XmlGeneratorArguments(
        bool(options.get("largePage")),
        options.get("metronome"),
        options.get("tempo"),
    )
    return config, xml_args


def main() -> int:
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))

    spec = json.load(sys.stdin)
    jobs = spec.get("jobs", [])
    options = spec.get("options", {})

    config, xml_args = build_config(options)
    emit(event="ready")

    for job in jobs:
        try:
            process_job(job, options, config, xml_args)
        except Exception as error:
            log(traceback.format_exc())
            emit(event="file_error", id=job.get("id"), message=str(error))

    emit(event="all_done")
    return 0


if __name__ == "__main__":
    sys.exit(main())
