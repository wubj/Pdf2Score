APP     := Pdf2Score
CONFIG  ?= release
ARCH    ?= $(shell uname -m)

# Friendly name for the disk image, so the recipient can tell which one is theirs.
ifeq ($(ARCH),arm64)
  LABEL  := AppleSilicon
  RUN_AS :=
else
  LABEL  := Intel
  RUN_AS := arch -x86_64
endif

RUNTIME := build/runtime-$(ARCH)
AUDIVERIS := build/audiveris-$(ARCH)
BUNDLE  := build/$(ARCH)/$(APP).app
DMG     := build/$(APP)-$(LABEL).dmg
BINDIR   = $(shell swift build -c $(CONFIG) --arch $(ARCH) --show-bin-path)
VENV     = $$HOME/Library/Application Support/Pdf2Score/venv/bin/python

.PHONY: help app dmg dmg-all run icon guide runtime audiveris install clean test

help:
	@echo "make app                 # .app for this Mac's architecture"
	@echo "make dmg                 # disk image for this Mac's architecture"
	@echo "make dmg ARCH=x86_64     # Intel disk image (needs Rosetta to build)"
	@echo "make dmg-all             # both disk images"
	@echo "make test [ARCH=...]     # end-to-end checks against samples/"
	@echo "make audiveris           # fetch the second recognition engine"
	@echo "make guide               # rebuild both user guides from docs/src/"

## Assemble a real, double-clickable .app around the SwiftPM executable.
## Includes the self-contained Python runtime when it has been built.
app: icon
	swift build -c $(CONFIG) --arch $(ARCH)
	rm -rf "$(BUNDLE)"
	mkdir -p "$(BUNDLE)/Contents/MacOS" "$(BUNDLE)/Contents/Resources"
	cp "$(BINDIR)/$(APP)" "$(BUNDLE)/Contents/MacOS/$(APP)"
	cp Resources/Info.plist "$(BUNDLE)/Contents/Info.plist"
	cp -R Resources/python "$(BUNDLE)/Contents/Resources/python"
	rm -rf "$(BUNDLE)/Contents/Resources/python/__pycache__"
	@if [ -d "$(RUNTIME)/python" ]; then \
		echo "embedding $(ARCH) Python runtime"; \
		cp -R "$(RUNTIME)/python" "$(BUNDLE)/Contents/Resources/python-runtime"; \
		find "$(BUNDLE)/Contents/Resources/python-runtime" \
			\( -name '__pycache__' -o -name '*.coreml_cache' \) -type d -prune -exec rm -rf {} +; \
	else \
		echo "no $(ARCH) runtime (run 'make runtime ARCH=$(ARCH)' for a distributable build)"; \
	fi
	@if [ -d "$(AUDIVERIS)/Audiveris.app" ]; then \
		echo "embedding $(ARCH) Audiveris"; \
		cp -R "$(AUDIVERIS)/Audiveris.app" "$(BUNDLE)/Contents/Resources/Audiveris.app"; \
	else \
		echo "no $(ARCH) Audiveris (run 'make audiveris ARCH=$(ARCH)' to include it)"; \
	fi
	@# macOS resolves zh-Hans to its own .lproj and will not fall back to
	@# zh-Hant, so a Simplified Chinese system would land on English. Ship a
	@# copy of the Traditional strings under zh-Hans to serve both.
	cp -R Resources/en.lproj "$(BUNDLE)/Contents/Resources/en.lproj"
	cp -R Resources/zh-Hant.lproj "$(BUNDLE)/Contents/Resources/zh-Hant.lproj"
	cp -R Resources/zh-Hant.lproj "$(BUNDLE)/Contents/Resources/zh-Hans.lproj"
	@if [ -f Resources/AppIcon.icns ]; then \
		cp Resources/AppIcon.icns "$(BUNDLE)/Contents/Resources/AppIcon.icns"; \
	fi
	printf 'APPL????' > "$(BUNDLE)/Contents/PkgInfo"
	@echo "signing (this takes a while with the runtime embedded)"
	@if [ -d "$(BUNDLE)/Contents/Resources/Audiveris.app" ]; then \
		codesign --force --deep --sign - "$(BUNDLE)/Contents/Resources/Audiveris.app"; \
	fi
	@find "$(BUNDLE)/Contents/Resources" -type f \( -name '*.so' -o -name '*.dylib' \) \
		-exec codesign --force --timestamp=none --sign - {} + 2>/dev/null || true
	@if [ -d "$(BUNDLE)/Contents/Resources/python-runtime/bin" ]; then \
		find "$(BUNDLE)/Contents/Resources/python-runtime/bin" -type f -perm -u+x \
			-exec codesign --force --timestamp=none --sign - {} + 2>/dev/null || true; \
	fi
	codesign --force --sign - "$(BUNDLE)"
	@echo "built $(BUNDLE) ($$(du -sh "$(BUNDLE)" | cut -f1))"

## Rebuild both user guides (docs/src/ -> docs/index.html and docs/en/).
guide:
	python3 Tools/build_guide.py

docs/index.html docs/en/index.html: $(wildcard docs/src/*) Tools/build_guide.py docs/icon/AppIcon-256.png
	python3 Tools/build_guide.py

## Extract the bundled Audiveris engine (ships its own JRE).
audiveris:
	./Tools/fetch_audiveris.sh $(ARCH)

$(AUDIVERIS):
	./Tools/fetch_audiveris.sh $(ARCH)

## Build the relocatable Python + homr + models that ships inside the app.
## Slow and network-heavy; the result is cached in build/runtime-$(ARCH).
runtime:
	./Tools/build_runtime.sh $(ARCH)

$(RUNTIME):
	./Tools/build_runtime.sh $(ARCH)

## A disk image to hand to someone else. Implies a fully self-contained app.
dmg: $(RUNTIME) $(AUDIVERIS) docs/index.html app
	@if [ ! -d "$(BUNDLE)/Contents/Resources/python-runtime" ]; then \
		echo "error: the app has no embedded runtime; run 'make runtime ARCH=$(ARCH)' first" >&2; \
		exit 1; \
	fi
	rm -rf build/dmg-$(ARCH) "$(DMG)"
	mkdir -p build/dmg-$(ARCH)
	cp -R "$(BUNDLE)" build/dmg-$(ARCH)/
	ln -s /Applications "build/dmg-$(ARCH)/應用程式"
	cp Resources/dmg-readme.txt "build/dmg-$(ARCH)/請先讀我.txt"
	cp docs/index.html "build/dmg-$(ARCH)/使用指南.html"
	cp docs/en/index.html "build/dmg-$(ARCH)/Guide.html"
	@# LZMA over zlib: ~11% smaller for a payload this size, at about 90 seconds
	@# of build time. Supported since macOS 10.15, well below our floor of 14.
	hdiutil create -volname "$(APP) $(LABEL)" -srcfolder build/dmg-$(ARCH) -ov \
		-format ULMO "$(DMG)"
	@echo "built $(DMG) ($$(du -sh "$(DMG)" | cut -f1))"

## Both architectures. Building the Intel image on Apple Silicon needs Rosetta.
dmg-all:
	$(MAKE) dmg ARCH=arm64
	$(MAKE) dmg ARCH=x86_64

## Run straight from the package (no bundle), handy while developing.
run:
	swift run -c debug $(APP)

## Draw the app icon with Pillow, using whichever Python environment exists.
icon: Resources/AppIcon.icns

Resources/AppIcon.icns: Tools/make_icon.py
	@PY="build/runtime-arm64/python/bin/python3"; \
	if [ ! -x "$$PY" ]; then PY="$(VENV)"; fi; \
	if [ -x "$$PY" ]; then \
		"$$PY" Tools/make_icon.py Resources/AppIcon.icns; \
	else \
		echo "skipping icon: no Python environment yet"; \
	fi

install: app
	rm -rf "/Applications/$(APP).app"
	cp -R "$(BUNDLE)" /Applications/
	@echo "installed /Applications/$(APP).app"

## End-to-end check of the Python side against the sample PDFs.
test:
	@PY="$(RUNTIME)/python/bin/python3"; \
	if [ ! -x "$$PY" ]; then PY="$(VENV)"; fi; \
	$(RUN_AS) "$$PY" Tools/test_worker.py

## Leaves build/cache, build/runtime-* and build/audiveris-* alone —
## rebuilding those is expensive.
clean:
	rm -rf build/arm64 build/x86_64 build/dmg-* build/*.dmg .build Resources/AppIcon.icns
