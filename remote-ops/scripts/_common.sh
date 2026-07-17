#!/usr/bin/env bash
# Shared helpers for the remote-ops skill: config resolution and non-interactive
# SSH option assembly. Sourced by ssh_run.sh and sync.sh — not run directly.
set -euo pipefail

# Auto-source a per-agent config file if present (env always wins, because we
# only set defaults for vars that are unset).
_cfg="${REMOTE_OPS_CONFIG:-remote-ops/config.env}"
if [ -f "$_cfg" ]; then set -a; . "$_cfg"; set +a; fi

: "${SSH_USER:=}"
: "${SSH_HOST:=}"
: "${SSH_PORT:=22}"
: "${SSH_KEY:=}"
: "${SSH_KNOWN_HOSTS:=.ssh/known_hosts}"   # relative to the agent's own folder: $HOME
                                           # is the server's home, outside the jail
: "${SSH_STRICT:=accept-new}"                          # accept-new | yes | no
: "${SSH_CONNECT_TIMEOUT:=15}"

# Emit the non-interactive ssh option list, one per line (read with mapfile).
ssh_opts() {
  mkdir -p "$(dirname "$SSH_KNOWN_HOSTS")" 2>/dev/null || true
  local o=(
    -o BatchMode=yes                          # never prompt for a password — fail fast
    -o StrictHostKeyChecking="$SSH_STRICT"
    -o UserKnownHostsFile="$SSH_KNOWN_HOSTS"
    -o ConnectTimeout="$SSH_CONNECT_TIMEOUT"
    -o ServerAliveInterval=15 -o ServerAliveCountMax=4
    -p "$SSH_PORT"
  )
  [ -n "$SSH_KEY" ] && o+=(-i "$SSH_KEY" -o IdentitiesOnly=yes)
  printf '%s\n' "${o[@]}"
}

# Resolve the target. An explicit "user@host" arg wins; otherwise SSH_USER@SSH_HOST.
target() {
  if [ -n "${1:-}" ]; then printf '%s' "$1"; return; fi
  [ -n "$SSH_HOST" ] || { echo "remote-ops: no host (set SSH_HOST or pass user@host)" >&2; exit 2; }
  if [ -n "$SSH_USER" ]; then printf '%s@%s' "$SSH_USER" "$SSH_HOST"; else printf '%s' "$SSH_HOST"; fi
}
