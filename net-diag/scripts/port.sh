#!/usr/bin/env bash
# TCP reachability check without netcat (uses bash's /dev/tcp). Usage:
#   port.sh HOST PORT [PORT...]
#   PORT_TIMEOUT=2 port.sh db.internal 5432
set -euo pipefail
host="${1:?usage: port.sh HOST PORT [PORT...]}"; shift
[ $# -ge 1 ] || { echo "port.sh: need at least one port" >&2; exit 2; }
to="${PORT_TIMEOUT:-5}"
rc=0
for p in "$@"; do
  if timeout "$to" bash -c "exec 3<>/dev/tcp/$host/$p" 2>/dev/null; then
    echo "$host:$p  open"
  else
    echo "$host:$p  closed/filtered"; rc=1
  fi
done
exit $rc
