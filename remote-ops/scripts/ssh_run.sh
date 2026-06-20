#!/usr/bin/env bash
# Run a command on a remote host, non-interactively. Usage:
#   ssh_run.sh [user@host] -- <command...>     # explicit target, or SSH_HOST from config
#   ssh_run.sh -- "uptime; df -h"
#   echo "$SCRIPT" | ssh_run.sh [user@host] --stdin     # pipe a script to remote bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; . "$here/_common.sh"

tgt=""; stdin=0
while [ $# -gt 0 ]; do
  case "$1" in
    --stdin) stdin=1; shift;;
    --) shift; break;;
    -*) echo "ssh_run.sh: unknown flag: $1" >&2; exit 2;;
    *) tgt="$1"; shift;;
  esac
done

mapfile -t OPTS < <(ssh_opts)
dest="$(target "$tgt")"

if [ "$stdin" = 1 ]; then
  exec ssh "${OPTS[@]}" "$dest" bash -s
fi
[ $# -gt 0 ] || { echo "ssh_run.sh: no command (… -- <command>)" >&2; exit 2; }
exec ssh "${OPTS[@]}" "$dest" "$@"
