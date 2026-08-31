#!/bin/bash
# Build the self-contained Python runtime that ships inside Pdf2Score.app.
#
#   ./Tools/build_runtime.sh [arm64|x86_64]     (defaults to this machine)
#
# Downloads a relocatable CPython (python-build-standalone), installs homr and
# its dependencies into it, pre-downloads the ONNX models, then prunes what a
# user never needs. The result is a directory that runs from anywhere, so the
# recipient needs no Python, no Homebrew and no network.
#
# Building the x86_64 runtime on an Apple Silicon Mac needs Rosetta 2
# (softwareupdate --install-rosetta).
set -euo pipefail

PYTHON_VERSION="3.13.15"
PBS_RELEASE="20260825"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$ROOT/build/cache"

ARCH="${1:-$(uname -m)}"
case "$ARCH" in
    arm64)  PBS_TRIPLE="aarch64-apple-darwin"; RUN_AS=() ;;
    x86_64) PBS_TRIPLE="x86_64-apple-darwin";  RUN_AS=(arch -x86_64) ;;
    *) echo "error: unknown architecture '$ARCH' (expected arm64 or x86_64)" >&2; exit 1 ;;
esac

RUNTIME="$ROOT/build/runtime-$ARCH"

if [ "$ARCH" = "x86_64" ] && [ "$(uname -m)" = "arm64" ]; then
    if ! arch -x86_64 /usr/bin/true 2>/dev/null; then
        echo "error: Rosetta 2 is required to build the x86_64 runtime here." >&2
        echo "       run: softwareupdate --install-rosetta" >&2
        exit 1
    fi
fi

ARCHIVE="cpython-${PYTHON_VERSION}+${PBS_RELEASE}-${PBS_TRIPLE}-install_only_stripped.tar.gz"
URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_RELEASE}/${ARCHIVE}"

mkdir -p "$CACHE"
if [ ! -f "$CACHE/$ARCHIVE" ]; then
    echo "==> downloading $ARCHIVE"
    curl -fL --progress-bar "$URL" -o "$CACHE/$ARCHIVE.part"
    mv "$CACHE/$ARCHIVE.part" "$CACHE/$ARCHIVE"
else
    echo "==> using cached $ARCHIVE"
fi

echo "==> extracting $ARCH runtime"
rm -rf "$RUNTIME"
mkdir -p "$RUNTIME"
tar -xzf "$CACHE/$ARCHIVE" -C "$RUNTIME"   # unpacks into $RUNTIME/python

PY=("${RUN_AS[@]}" "$RUNTIME/python/bin/python3")
"${PY[@]}" -c "import sys, platform; print(sys.version.split()[0], platform.machine())"

echo "==> installing packages"
"${PY[@]}" -m pip install --no-cache-dir --upgrade pip
if [ "$ARCH" = "x86_64" ]; then
    # onnxruntime stopped publishing macOS x86_64 wheels after 1.23.2, while
    # homr 0.7.0 pins >= 1.24.1. homr only calls long-stable onnxruntime APIs
    # (InferenceSession, OrtValue, set_default_logger_severity, preload_dlls),
    # so install homr without resolving its pin and supply the last Intel build.
    "${PY[@]}" -m pip install --no-cache-dir -r "$ROOT/Resources/python/requirements-x86_64.txt"
    "${PY[@]}" -m pip install --no-cache-dir --no-deps homr==0.7.0
else
    "${PY[@]}" -m pip install --no-cache-dir -r "$ROOT/Resources/python/requirements.txt"
fi

echo "==> downloading recognition models"
# Fetch only the set the recipient's machine will actually load. Apple Silicon
# runs segnet on CoreML (fp16); worker.py keeps Intel on the CPU (fp32), so
# shipping both would waste ~27 MB on every Intel download.
if [ "$ARCH" = "x86_64" ]; then
    "${PY[@]}" -m homr.main --init --gpu no
else
    "${PY[@]}" -m homr.main --init
fi

echo "==> pruning"
SITE="$(cd "$RUNTIME/python/lib" && echo python*/site-packages)"
cd "$RUNTIME/python"
# Byte-code caches rebuild on demand and are a large share of the bundle.
find . -name '__pycache__' -type d -prune -exec rm -rf {} +
find . -name '*.pyc' -delete
# CoreML compiles its own copies of the models on first use. Those are built on
# this machine and belong in the user's cache directory, not in the bundle.
find . -name '*.coreml_cache' -type d -prune -exec rm -rf {} +
# The OCR models exist only for homr's title detection, which worker.py switches
# off (it was wrong on every score we tried, and the file name is better). The
# rapidocr package itself has to stay — homr imports it — but its ~31 MB of
# model files are never opened.
rm -rf "lib/$SITE/rapidocr/models"
# Nothing installs packages at runtime, so the installer toolchain can go.
rm -rf "lib/$SITE/pip" "lib/$SITE/pip-"*.dist-info
rm -rf "lib/$SITE/setuptools" "lib/$SITE/setuptools-"*.dist-info
rm -rf "lib/$SITE/pkg_resources"
# Test suites shipped inside the packages.
rm -rf lib/python*/test lib/python*/idlelib lib/python*/tkinter
rm -rf "lib/$SITE/numpy/_core/tests" "lib/$SITE/numpy/"*/tests
rm -rf "lib/$SITE/onnxruntime/transformers"
rm -f lib/*/config-*/libpython*.a

echo "==> done ($ARCH)"
du -sh "$RUNTIME/python"
