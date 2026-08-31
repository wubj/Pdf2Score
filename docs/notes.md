# Engineering notes

Why parts of this project look the way they do. Most of these cost real
debugging time, so they are written down rather than left to be rediscovered.

## Both pipes must be drained off the main actor

`WorkerRunner` reads the worker's stdout and stderr with `readabilityHandler`,
each on its own background queue. This is not tidy-up-later detail: reading them
from the main actor **deadlocks**.

Two reads on one thread run in turn, so whichever pipe is not currently being
read fills its 64 KB buffer. The worker then blocks writing to it, no further
output arrives on the pipe that *is* being read, and neither side ever moves
again. It presents as a conversion stuck on its first file with both processes
sitting at 0% CPU, and — because it depends on how much the engine happens to
write to stderr — it is **intermittent**. It passed nine runs out of ten.

The diagnostic that settled it was `lsof` on the stuck Python process:

```
fd 1  PIPE 0x3a4c...  65536   <- full
fd 2  PIPE 0x3a4c...  65536   <- same pipe (worker.py dup2's stderr onto stdout)
```

`Tools/test_worker.py` cannot cover this path — it only exercises the Python
side. The app therefore keeps a `--convert` flag so the Swift → worker path can
be driven from a terminal:

```bash
./build/arm64/Pdf2Score.app/Contents/MacOS/Pdf2Score --convert /path/to/score.pdf --engine homr
```

`open -n <app> --args --convert <pdf>` reproduces a real GUI launch, including
Gatekeeper's first-run scan, and writes a transcript to
`/tmp/pdf2score-harness.log`.

## The Intel build pins an older onnxruntime

onnxruntime stopped publishing macOS x86_64 wheels after **1.23.2**, while homr
0.7.0 requires `>= 1.24.1`. Following that pin, Intel Macs cannot install it at
all.

homr only calls onnxruntime APIs that have been stable for years
(`InferenceSession`, `OrtValue.ortvalue_from_numpy`,
`set_default_logger_severity`, `preload_dlls`), so the Intel build installs homr
with `--no-deps` and supplies `onnxruntime==1.23.2` from
`Resources/python/requirements-x86_64.txt`. Recognition output is byte-identical
to the arm64 build on the test scores. Because that bypasses dependency
resolution, the file has to name `musicxml==1.4` itself — homr 0.7.0 still
depends on it, and forgetting it fails only at import time.

Intel also stays on the CPU deliberately, even though onnxruntime lists the
CoreML provider there. Intel Macs have no Neural Engine behind CoreML, and a
provider that fails to initialise would take down a conversion on a machine the
user cannot debug. Verified under Rosetta only — no real Intel hardware was
available.

## Title detection is switched off

homr runs OCR across the top of each page to guess the title. It was wrong on
every score tested — "Test One Page" came back as `Tcst One T age` — so
`worker.py` replaces `homr.main.detect_title` with a stub and `ensure_title()`
falls back to the file name instead. More accurate, 1–2 seconds faster per
score, and it lets `Tools/build_runtime.sh` delete rapidocr's 31 MB of model
files. The rapidocr package itself has to stay: homr imports it at module level,
it is simply never instantiated.

## What could not be trimmed

`cv2/.dylibs` holds 78 MB of video codecs (libavcodec, x265, aom, rav1e…) while
this project only ever reads static PNGs. They look like dead weight, but
`cv2.abi3.so` links libavformat / libavcodec / libavdevice directly — deleting
libx265 makes `import cv2` fail with a dyld error. Removing them means rebuilding
OpenCV.

Audiveris's bundled JRE is 107 MB, 80 MB of which is `lib/modules`. A jlink pass
could plausibly halve it, but that means repackaging Audiveris from source, and
Java's reflection-heavy dependencies make an over-trimmed module set fail only at
runtime. Not attempted.

## Bundle hygiene

- Python writes `__pycache__` next to the source by default, which lands **inside
  the signed app bundle** and breaks its seal (`a sealed resource is missing or
  invalid`). `WorkerRunner.workerEnvironment()` sets `PYTHONPYCACHEPREFIX` to
  `~/Library/Caches/Pdf2Score/pycache` instead.
- The CoreML execution provider caches compiled models next to the `.onnx` file,
  which has the same problem. `worker.py` points it at
  `~/Library/Caches/Pdf2Score/coreml` via `HOMR_COREML_MODEL_CACHE_DIR`.
- The first launch after installing is slow — minutes, for a bundle this size —
  because macOS verifies every file in an unnotarised bundle. Both engines are
  warmed up in the background at launch so that cost is paid while the user is
  still choosing files, and the queue shows "啟動辨識引擎…" rather than looking
  frozen. Each engine is verified separately the first time its own binaries
  load, which is why the warm-up touches both.

## The Audiveris path skips the page splitting

Audiveris reads PDFs itself and treats a multi-page file as one book, so
`process_job_audiveris()` hands over the whole PDF and never uses
`render_pages()` or `merge_pages()`. It writes a `.omr` project file and a `.log`
beside its output, so it is pointed at a temp folder and only the `.mxl` is moved
into place. Progress comes from parsing `End of Stub#N` out of its log.

Its published disk image carries a click-through of the AGPL, which blocks a
scripted mount; `Tools/fetch_audiveris.sh` runs `hdiutil convert` first and
copies the app out of the plain image.

## Disk image format

`make dmg` builds with `-format ULMO` (LZMA) rather than the usual zlib: about
11% smaller for a payload this size, at roughly 90 seconds of extra build time.
Supported since macOS 10.15, well below this project's floor of 14.
