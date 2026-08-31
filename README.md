<img src="docs/icon/AppIcon-256.png" width="112" alt="Pdf2Score">

# Pdf2Score

**Turn PDF sheet music into files MuseScore can open.** Drag in a stack of PDFs,
get a `.mxl` for each one. Two recognition engines, switchable per batch. Runs
entirely on your Mac — no account, no network, nothing uploaded.

繁體中文說明在下半部 · [User guide](https://wubj.github.io/Pdf2Score/en/) · [使用指南](https://wubj.github.io/Pdf2Score/)

---

## Download

| Your Mac | File |
|---|---|
| Apple Silicon (M1 and later) | [Pdf2Score-AppleSilicon.dmg](https://github.com/wubj/Pdf2Score/releases/latest/download/Pdf2Score-AppleSilicon.dmg) — about 280 MB |
| Intel | [Pdf2Score-Intel.dmg](https://github.com/wubj/Pdf2Score/releases/latest/download/Pdf2Score-Intel.dmg) — about 310 MB |

Requires **macOS 14 or later**. Apple menu → About This Mac tells you which
chip you have; the wrong build will not open.

The app is ad-hoc signed and **not notarised**, so the first launch needs
right-click → Open, or System Settings → Privacy & Security → Open Anyway.
The [illustrated guide](https://wubj.github.io/Pdf2Score/en/) walks through it.

## What it does

- Drag in any number of PDFs, or a whole folder — it finds the PDFs inside.
- Each PDF becomes one `.mxl` (compressed MusicXML) next to the original, or in
  a folder you choose. Multi-page scores are stitched into a single piece.
- **Two engines, switched from the toolbar.** They fail differently, so trying
  the other one is the most useful thing to do with a bad result:
  - **homr** — vision transformer; copes better with photographed, skewed or
    soft-focus scans.
  - **Audiveris** — classical structural analysis; very steady on clean
    engraving, and reads multi-page PDFs as one book itself.
  - Right-click a finished row → *re-recognise with the other engine* produces a
    second file so you can compare.
- Roughly 5 s per page with homr on Apple Silicon, ~9 s with Audiveris; Intel
  Macs are noticeably slower.

## Optical music recognition is never perfect

**Everything it produces needs proofreading in MuseScore.** Clean engraving
comes out well; skewed scans, repeated photocopies, handwriting and dense piano
writing produce noticeably more errors. This tool saves you the re-typing, not
the checking. On one real scanned viola part the two engines disagreed by four
bars — neither was fully right.

## Privacy

Recognition models and both engines are inside the app. Conversion happens on
your machine, needs no network, and no score ever leaves it.

## Build from source

```bash
make dmg-all      # both architectures
make dmg          # just this Mac's
make test         # end-to-end checks against samples/
```

The first build downloads and assembles a self-contained Python runtime
(~15 minutes per architecture) and extracts Audiveris; both are cached under
`build/`. Building the Intel image on an Apple Silicon Mac needs Rosetta 2
(`softwareupdate --install-rosetta`). `make help` lists the targets.

Engineering notes — the pipe deadlock, why the Intel build pins an older
onnxruntime, why title detection is off, what could not be trimmed — are in
[docs/notes.md](docs/notes.md).

## Layout

```
Sources/Pdf2Score/       SwiftUI front end: drop queue, progress, settings, first-run setup
Resources/python/        the part that does the work
  worker.py              long-lived worker for a whole batch, reports progress as NDJSON
  musicxml_merge.py      stitches per-page MusicXML into one score
  mxl.py                 packs the .mxl container
Tools/build_runtime.sh   assembles the self-contained Python runtime
Tools/fetch_audiveris.sh extracts the bundled Audiveris (which ships its own JRE)
Tools/test_worker.py     the test suite
docs/                    the user guide published via GitHub Pages
samples/                 synthetic test scores
```

## License

**AGPL-3.0** — see [LICENSE](LICENSE). Not a free choice: the embedded engines
[homr](https://github.com/liebharc/homr) and
[Audiveris](https://github.com/Audiveris/audiveris) are both AGPL-3.0, so the
combined work must be too. [NOTICE.md](NOTICE.md) lists every third-party
component and its license.

---

# Pdf2Score（繁體中文）

**把 PDF 樂譜轉成 MuseScore 打得開的檔案。** 拖一批 PDF 進去，每份產生一個
`.mxl`。內建兩個辨識引擎可隨時切換。全部在你自己的 Mac 上跑——不用註冊、
不需網路、樂譜不會上傳到任何地方。

## 下載

| 你的 Mac | 檔案 |
|---|---|
| Apple Silicon（M1 以後） | [Pdf2Score-AppleSilicon.dmg](https://github.com/wubj/Pdf2Score/releases/latest/download/Pdf2Score-AppleSilicon.dmg) — 約 280 MB |
| Intel | [Pdf2Score-Intel.dmg](https://github.com/wubj/Pdf2Score/releases/latest/download/Pdf2Score-Intel.dmg) — 約 310 MB |

需要 **macOS 14 以上**。蘋果選單 →「關於這台 Mac」可以看到晶片是哪一種，
**拿錯的那份打不開**。

App 只有 ad-hoc 簽章、**沒有經過 Apple 公證**，所以第一次開啟要右鍵 →「打開」，
或到「系統設定 →「隱私權與安全性」按「仍要打開」。
[圖文使用指南](https://wubj.github.io/Pdf2Score/)有每一步的說明。

## 能做什麼

- 一次拖幾個 PDF 都可以，拖整個資料夾也行——它會自己找出裡面的 PDF。
- 每份 PDF 產生一個 `.mxl`，放在原檔旁邊或你指定的資料夾。多頁的曲子會自動
  接成完整一份。
- **兩個引擎，在工具列直接切換。** 它們的失敗方式不同，所以結果不理想時
  換另一個再試，通常比調任何設定有效：
  - **homr** — 以 vision transformer 辨識，對拍照、掃描歪斜、印刷較模糊的譜
    比較有辦法。
  - **Audiveris** — 傳統樂譜結構分析，對乾淨的印刷譜很穩，多頁 PDF 由它自己
    整份處理。
  - 已完成的項目按右鍵 →「改用 ⋯ 重新辨識」會另外產生一個檔案，兩份可以直接比對。
- Apple Silicon 上 homr 每頁約 5 秒、Audiveris 約 9 秒；Intel 機型會明顯慢一些。

## 樂譜辨識不可能全對

**轉出來的東西一定要在 MuseScore 裡校對。** 印刷清晰的譜結果相當好；掃描歪斜、
影印很多次、手寫譜、聲部密集的鋼琴譜錯誤會明顯變多。這個工具幫你省的是重新
輸入的功夫，不是校對。實測一份真實掃描的中提琴分譜，兩個引擎的小節數差了四小節，
而且沒有一個完全正確。

## 隱私

辨識模型和兩個引擎都包在 App 裡面，轉檔全程在你的電腦上完成，不需要網路，
樂譜不會離開你的機器。

## 自行建置

```bash
make dmg-all      # 兩種架構都建
make dmg          # 只建這台機器的架構
make test         # 用 samples/ 跑端對端測試
```

第一次建置會下載並組出自足的 Python 執行環境（每個架構約 15 分鐘），並抽出
Audiveris，兩者都快取在 `build/` 下。在 Apple Silicon 上建 Intel 版需要
Rosetta 2（`softwareupdate --install-rosetta`）。`make help` 會列出所有目標。

開發筆記（管線死結、Intel 版為何要釘舊版 onnxruntime、為何關掉標題偵測、
哪些體積砍不掉）在 [docs/notes.md](docs/notes.md)，內容是英文。

## 授權

**AGPL-3.0** —— 見 [LICENSE](LICENSE)。這不是自由選擇：內建的
[homr](https://github.com/liebharc/homr) 與
[Audiveris](https://github.com/Audiveris/audiveris) 都是 AGPL-3.0，
所以結合後的作品也必須是。[NOTICE.md](NOTICE.md) 列出所有第三方元件與各自的授權。
