#!/usr/bin/env bash
# Show the agent's outbound public IP (and org/geo) — what the world sees as the
# source of the agent's traffic. There is no VPN or egress proxy: this is the
# cluster node's own public IP, which is the expected answer. Use it to tell a
# remote admin which address to allowlist.
set -euo pipefail
ip="$(curl -fsS --max-time 10 https://api.ipify.org)" \
  || { echo "egress.sh: could not reach api.ipify.org (no egress — check DNS and the pod NetworkPolicy)" >&2; exit 1; }
echo "public IP: $ip"
geo="$(curl -fsS --max-time 10 "https://ipinfo.io/$ip/json" 2>/dev/null || true)"
if [ -n "$geo" ] && command -v jq >/dev/null; then
  printf '%s' "$geo" | jq -r '"org: \(.org // "?")\nlocation: \(.city // "?"), \(.region // "?"), \(.country // "?")"' 2>/dev/null || true
fi
