---
name: archives
requires: tar, gzip, xz, zstd, zip, unzip, file
description: >
  Create, list, and extract archives in the formats the image ships — tar with
  gzip/xz/zstd compression, plain tar, and zip — with one helper that picks the
  format automatically. Use whenever the user wants to unzip/untar/extract an
  archive, decompress a .zip/.tar.gz/.tgz/.tar.xz/.tar.zst file, package a folder
  into an archive, compress files for transfer or backup, peek inside an archive
  without extracting it, or repackage between formats. Trigger phrases: "unzip",
  "extract", "untar", "decompress", "open this archive", "tar up", "zip up",
  "compress this folder", "package these files", "what's inside this archive",
  "make a tarball", ".tar.gz", ".tar.zst", ".tar.xz", ".zip".
---

# archives — create / list / extract, any baked format

`scripts/ar.sh` wraps `tar`, the standalone compressors (`xz`, `zstd`, `gzip`),
and `unzip`/`zip`, detecting the format from the filename. It exists because the
image's `tar` is busybox's — which doesn't take GNU flags like `-J`/`--zstd`
reliably — so the script pipes through the right compressor explicitly instead of
trusting tar's auto-handling. The agent doesn't have to remember which flag goes
with which extension.

```
skills/archives/
└── scripts/ar.sh      # list | extract | create
```

Paths are relative to the **workspace root**.

## Usage

```bash
ar=skills/archives/scripts/ar.sh

# look inside without extracting
bash $ar list release.tar.zst

# extract (default destination: current dir; pass a dir to extract into it)
bash $ar extract release.tar.gz
bash $ar extract data.zip ./unpacked/

# create — the OUTPUT extension picks the format
bash $ar create backup.tar.zst ./project ./notes.md     # zstd (fast, modern)
bash $ar create site.tar.gz ./public                     # gzip (max compatibility)
bash $ar create logs.tar.xz ./logs                       # xz (smallest)
bash $ar create bundle.zip ./docs                        # zip
```

Supported by extension: `.tar`, `.tar.gz`/`.tgz`, `.tar.xz`/`.txz`,
`.tar.zst`/`.tzst`, `.zip`, and raw single-file `.gz`/`.xz`/`.zst` (extract only).
For extract/list, if the extension is unfamiliar the script falls back to `file`
magic-byte detection.

## Notes

- **Format choice:** `zstd` for speed (great for routine backups), `xz` for the
  smallest output (slowest), `gzip` for maximum compatibility, `zip` when a
  non-Unix recipient needs it. `install-runtimes` fetches `.tar.xz`/`.tar.zst`, so
  those decompressors are present for a reason.
- **`.zip` support:** both `zip` and `unzip` are baked, so creation and
  extraction work directly. (`ar.sh` also falls back to `python3`'s `zipfile`
  for zip creation on a leaner image built without the `zip` package.)
- Extraction writes under the agent's folder — fine under the Landlock write-jail.
  Be wary of archives with absolute or `../` paths; extract into a fresh subdir
  (`bash $ar extract foo.tar.gz ./unpacked/`) and inspect before moving files out.
- For *fetching* an archive first, use `curl -fLO <url>` (or the web skills), then
  hand the file to `ar.sh`.
