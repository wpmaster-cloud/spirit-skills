#!/usr/bin/env bash
# Create, list, and extract archives across the formats the image ships. Format
# is taken from the filename; compression is piped through the standalone tool
# (xz/zstd/gzip) rather than relying on busybox tar's flag support. Usage:
#   ar.sh list    <archive>
#   ar.sh extract <archive> [dest_dir]      # default dest: current dir
#   ar.sh create  <archive> <path> [path…]  # format chosen by <archive> extension
set -euo pipefail

cmd="${1:-}"; shift || true
ar="${1:-}"; shift || true
[ -n "$cmd" ] && [ -n "$ar" ] || { echo "usage: ar.sh list|extract|create ARCHIVE [...]" >&2; exit 2; }

decompressor() {  # echo the streaming decompressor for a name; nonzero if not compressed-tar/raw
  case "$1" in
    *.tar.gz|*.tgz)   echo "gzip -dc";;
    *.tar.xz|*.txz)   echo "xz -dc";;
    *.tar.zst|*.tzst) echo "zstd -dc";;
    *.tar)            echo "cat";;
    *) return 1;;
  esac
}

case "$cmd" in
  create)
    [ $# -ge 1 ] || { echo "ar.sh create: need at least one path" >&2; exit 2; }
    case "$ar" in
      *.zip)
        # Prefer the `zip` binary (baked into the image); fall back to python3's
        # zipfile for a leaner image built without it; else point to tar formats.
        if command -v zip >/dev/null; then
          zip -r -q "$ar" "$@"
        elif command -v python3 >/dev/null; then
          python3 - "$ar" "$@" <<'PY'
import os, sys, zipfile
out = sys.argv[1]
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    for p in sys.argv[2:]:
        if os.path.isdir(p):
            for root, _, files in os.walk(p):
                for f in files:
                    fp = os.path.join(root, f)
                    z.write(fp, fp)
        else:
            z.write(p, p)
PY
        else
          echo "ar.sh: creating .zip needs the 'zip' package or python3 (neither present) — use a .tar.gz/.tar.xz/.tar.zst instead" >&2; exit 2
        fi;;
      *.tar)            tar -cf "$ar" "$@";;
      *.tar.gz|*.tgz)   tar -cf - "$@" | gzip > "$ar";;
      *.tar.xz|*.txz)   tar -cf - "$@" | xz > "$ar";;
      *.tar.zst|*.tzst) tar -cf - "$@" | zstd -q > "$ar";;
      *) echo "ar.sh: don't know how to create '$ar' (use .tar.gz/.tar.xz/.tar.zst/.zip)" >&2; exit 2;;
    esac
    echo "created $ar";;

  list)
    [ -f "$ar" ] || { echo "ar.sh: no such file: $ar" >&2; exit 1; }
    case "$ar" in
      *.zip) unzip -l "$ar";;
      *) if dec="$(decompressor "$ar")"; then $dec "$ar" | tar -tf -
         else
           case "$(file -b --mime-type "$ar" 2>/dev/null)" in
             application/zip) unzip -l "$ar";;
             application/x-tar) tar -tf "$ar";;
             application/gzip) gzip -dc "$ar" | tar -tf -;;
             application/x-xz) xz -dc "$ar" | tar -tf -;;
             application/zstd) zstd -dc "$ar" | tar -tf -;;
             *) echo "ar.sh: unknown archive type for $ar" >&2; exit 2;;
           esac
         fi;;
    esac;;

  extract)
    [ -f "$ar" ] || { echo "ar.sh: no such file: $ar" >&2; exit 1; }
    dest="${1:-.}"; mkdir -p "$dest"
    case "$ar" in
      *.zip) unzip -o "$ar" -d "$dest";;
      *.gz)  [ "${ar%.tar.gz}" = "$ar" ] && [ "${ar%.tgz}" = "$ar" ] \
               && gzip -dc "$ar" > "$dest/$(basename "${ar%.gz}")" \
               || gzip -dc "$ar" | tar -xf - -C "$dest";;
      *.xz)  [ "${ar%.tar.xz}" = "$ar" ] && [ "${ar%.txz}" = "$ar" ] \
               && xz -dc "$ar" > "$dest/$(basename "${ar%.xz}")" \
               || xz -dc "$ar" | tar -xf - -C "$dest";;
      *.zst) [ "${ar%.tar.zst}" = "$ar" ] && [ "${ar%.tzst}" = "$ar" ] \
               && zstd -dc "$ar" > "$dest/$(basename "${ar%.zst}")" \
               || zstd -dc "$ar" | tar -xf - -C "$dest";;
      *.tar) tar -xf "$ar" -C "$dest";;
      *) case "$(file -b --mime-type "$ar" 2>/dev/null)" in
           application/zip) unzip -o "$ar" -d "$dest";;
           application/x-tar) tar -xf "$ar" -C "$dest";;
           application/gzip) gzip -dc "$ar" | tar -xf - -C "$dest";;
           application/x-xz) xz -dc "$ar" | tar -xf - -C "$dest";;
           application/zstd) zstd -dc "$ar" | tar -xf - -C "$dest";;
           *) echo "ar.sh: unknown archive type for $ar" >&2; exit 2;;
         esac;;
    esac
    echo "extracted → $dest";;

  *) echo "ar.sh: unknown subcommand '$cmd' (list|extract|create)" >&2; exit 2;;
esac
