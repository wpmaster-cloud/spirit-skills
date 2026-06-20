#!/usr/bin/env bash
# rsync push/pull over the non-interactive SSH transport. DRY RUN by default —
# add --go to actually transfer. Usage:
#   sync.sh push <local_src> <remote_dst> [user@host] [--go] [-- extra rsync args]
#   sync.sh pull <remote_src> <local_dst> [user@host] [--go] [-- extra rsync args]
# Defaults to  -az --partial  with stats. Mirror with:  ... --go -- --delete
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; . "$here/_common.sh"

dir="${1:-}"; src="${2:-}"; dst="${3:-}"
[ -n "$dir" ] && [ -n "$src" ] && [ -n "$dst" ] || {
  echo "usage: sync.sh push|pull SRC DST [user@host] [--go] [-- rsync args]" >&2; exit 2; }
shift 3

tgt=""; go=0; extra=()
while [ $# -gt 0 ]; do
  case "$1" in
    --go) go=1; shift;;
    --) shift; extra+=("$@"); break;;
    -*) echo "sync.sh: unknown flag: $1" >&2; exit 2;;
    *) tgt="$1"; shift;;
  esac
done

mapfile -t OPTS < <(ssh_opts)
dest="$(target "$tgt")"
rsh="ssh ${OPTS[*]}"

flags=(-az --partial --human-readable --info=stats1,progress2)
[ "$go" = 1 ] || flags+=(--dry-run)

case "$dir" in
  push) rsync "${flags[@]}" -e "$rsh" "${extra[@]}" "$src" "$dest:$dst";;
  pull) rsync "${flags[@]}" -e "$rsh" "${extra[@]}" "$dest:$src" "$dst";;
  *) echo "sync.sh: first arg must be 'push' or 'pull'" >&2; exit 2;;
esac

[ "$go" = 1 ] || echo "[dry-run] nothing changed — re-run with --go to apply" >&2
