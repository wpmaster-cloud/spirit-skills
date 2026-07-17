---
name: markitdown
requires: python3
description: "Convert common files to Markdown (.md) using Microsoft MarkItDown. Use this skill whenever the user wants to turn a PDF, Word (.docx), PowerPoint (.pptx), Excel (.xlsx/.xls), image (PNG/JPG, with EXIF + optional OCR/captioning), audio (.wav/.mp3, with transcription), HTML, CSV, JSON, XML, EPUB, Outlook (.msg), ZIP archive, or even a YouTube URL into clean Markdown for reading, summarizing, or feeding to an LLM. Triggers include: 'convert X to markdown', 'to .md', 'extract the text from this PDF/doc/deck/sheet', 'read this file as markdown', or batch-converting a folder of documents. This skill is read-only extraction TO Markdown — for CREATING or EDITING Office files use the docx/pptx/xlsx skills instead."
markitdown_repo: https://github.com/microsoft/markitdown
last_updated: 2026-06-05
---

# MarkItDown — files → Markdown

[MarkItDown](https://github.com/microsoft/markitdown) is a Python tool from Microsoft that converts many file types into clean, LLM-friendly Markdown. It ships a `markitdown` CLI and a Python API.

## When to use it
- "Convert / extract / read this `<PDF/Word/PowerPoint/Excel/image/audio/HTML/CSV/...>` as Markdown."
- Batch-converting a directory of mixed documents into `.md`.
- Pulling a transcript from a YouTube URL, or text+structure out of a `.zip`/`.epub`/`.msg`.

Do **not** use this skill to author or edit Office documents — that's the `docx`, `pptx`, and `xlsx` skills.

For reading a **live web page** (especially a JavaScript-rendered one), use the
`web-extraction` skill instead — MarkItDown's `HTML` support is best for a
*local* `.html` file you already have, not for fetching and cleaning pages off
the web.

## Step 1 — Install it (do this first)

The runtime does not ship MarkItDown. Install it once with the bundled idempotent script; it's safe to re-run (it no-ops if `markitdown` is already on `PATH`):

```bash
bash skills/markitdown/scripts/setup.sh
```

`setup.sh` will:
1. find a Python ≥ 3.10 (MarkItDown's minimum; the image ships CPython 3.12),
2. install `markitdown[all]` via the first available isolated installer — `uv tool` → `pipx` → a dedicated venv. **Here it always takes the venv path**: neither `uv` nor `pipx` is in the image, and a bare `pip install` is refused outright (`error: externally-managed-environment`, PEP 668). The venv path works and is the one to expect,
3. best-effort install the optional system deps `ffmpeg` + `exiftool` via apt when available — this step **no-ops on Alpine**. `ffmpeg` is already baked into the image, so only `exiftool` (image/audio metadata) is genuinely absent,
4. verify `markitdown --version`.

**Install a subset instead of everything** (smaller, faster) by setting `MARKITDOWN_EXTRAS` before running setup:

```bash
MARKITDOWN_EXTRAS="pdf,docx,pptx,xlsx" bash skills/markitdown/scripts/setup.sh
```

### Manual install (if you prefer / setup.sh can't run)
MarkItDown requires **Python 3.10+**. Use an isolated environment — on this
runtime a venv is the only option, and it is not optional: `pip install` outside
one fails with `error: externally-managed-environment` (PEP 668).

```bash
# The path that works here — create the venv INSIDE your own folder (the jail
# denies writes outside it; ~ is the server's home, not yours).
python3 -m venv .venv
./.venv/bin/pip install 'markitdown[all]'
./.venv/bin/markitdown --version        # call it by path; each command is a fresh shell

# Elsewhere (a host with pipx/uv), either of these is tidier:
#   pipx install 'markitdown[all]'
#   uv tool install 'markitdown[all]'
```

Available extras (install only what you need): `[all]`, `[pdf]`, `[docx]`, `[pptx]`, `[xlsx]`, `[xls]`, `[outlook]`, `[audio-transcription]`, `[youtube-transcription]`, `[az-doc-intel]`, `[az-content-understanding]`. Example: `pip install 'markitdown[pdf, docx, pptx]'`.

Python 3.12 is already in the image, so the "no Python" case does not arise
here. On another host without it, see the **install-runtimes** skill.

## Step 2 — Convert

### Easiest: the bundled wrapper
Ensures install, then converts. Defaults the output to `<input>.md` next to the source:

```bash
# single file  ->  report.md
bash skills/markitdown/scripts/to_md.sh report.pdf

# explicit output path
bash skills/markitdown/scripts/to_md.sh deck.pptx out/deck.md

# whole folder (recurses; mirrors structure into <dir>-md/)
bash skills/markitdown/scripts/to_md.sh -r ./documents ./documents-md
```

### Or the `markitdown` CLI directly
```bash
# write to a file
markitdown path-to-file.pdf -o document.md

# or stream to stdout / pipe in
markitdown path-to-file.pdf > document.md
cat path-to-file.pdf | markitdown > document.md
```

### Python API
```python
from markitdown import MarkItDown

md = MarkItDown(enable_plugins=False)   # set True to load installed plugins
result = md.convert("test.xlsx")
print(result.text_content)              # the Markdown string
```

## Supported inputs
PDF · Word `.docx` · PowerPoint `.pptx` · Excel `.xlsx` / `.xls` · images (EXIF metadata; descriptions/OCR with an LLM, see below) · audio `.wav` / `.mp3` (metadata + transcription) · HTML · text formats (CSV, JSON, XML) · EPUB · Outlook `.msg` · ZIP (iterates and converts contents) · YouTube URLs.

## Optional power-ups

### LLM image descriptions / OCR
For images and slide pictures, MarkItDown can caption images via an OpenAI-compatible client:

```python
import os
from markitdown import MarkItDown
from openai import OpenAI

# Any OpenAI-compatible vision model works — point the client at your provider.
# Here: Anthropic via its OpenAI-compatible endpoint, using spirit's LLM_API_KEY.
client = OpenAI(api_key=os.environ["LLM_API_KEY"],
                base_url="https://api.anthropic.com/v1")
md = MarkItDown(llm_client=client, llm_model="claude-sonnet-4-6",
                llm_prompt="optional custom prompt")
result = md.convert("example.jpg")
print(result.text_content)
```

(Plain OpenAI works too: `client = OpenAI()` honors `OPENAI_API_KEY` /
`OPENAI_BASE_URL` — just give `llm_model` a current vision model.)

For OCR text inside embedded images (PDF/DOCX/PPTX/XLSX), add the plugin:
```bash
pip install markitdown-ocr openai
markitdown --use-plugins document_with_images.pdf -o out.md
```

### Plugins
```bash
markitdown --list-plugins              # show installed plugins (disabled by default)
markitdown --use-plugins file.pdf      # enable them for this run
```

### Azure Document Intelligence (higher-quality scanned-PDF/layout extraction)
```bash
markitdown path-to-file.pdf -o document.md -d -e "<document_intelligence_endpoint>"
```

### Docker (no local Python)
```bash
docker build -t markitdown:latest https://github.com/microsoft/markitdown.git
docker run --rm -i markitdown:latest < your-file.pdf > output.md
```

## Troubleshooting
- **`markitdown: command not found` after install** — the venv shim may be at `~/.local/bin`; ensure it's on `PATH` (`export PATH="$HOME/.local/bin:$PATH"`), or call the venv binary directly (setup.sh prints its path).
- **A format errors out / produces empty output** — that format's optional deps aren't installed. Re-run with `[all]` or add the specific extra (e.g. `pip install 'markitdown[pptx]'`).
- **Audio transcription does nothing** — needs `[audio-transcription]` plus `ffmpeg` on the system.
- **Python too old** — MarkItDown needs 3.10+. Install a newer Python (see the install options above) and re-run `setup.sh`.
- **Empty Markdown from a scanned PDF** — it's an image-only PDF; use the `markitdown-ocr` plugin with an LLM, or Azure Document Intelligence (`-d -e ...`).

## Files in this skill
- `scripts/setup.sh` — idempotent installer (uv → pipx → venv), honors `MARKITDOWN_EXTRAS`.
- `scripts/to_md.sh` — convenience wrapper: ensures install, converts a single file or a whole directory.
