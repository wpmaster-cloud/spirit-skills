#!/usr/bin/env bash
# Show the agent's outbound public IP (and org/geo) — what the world sees as the
# source of the agent's traffic. On a VPN-enabled agent (the :vpn image) this is
# the NordVPN exit IP, not the host/node IP. Set NODE_IP to the host's own public
# IP to get a warning when egress is NOT going through the tunnel.
set -euo pipefail
ip="$(curl -fsS --max-time 10 https://api.ipify.org)" \
  || { echo "egress.sh: could not reach api.ipify.org (no egress / VPN down?)" >&2; exit 1; }
echo "public IP: $ip"
geo="$(curl -fsS --max-time 10 "https://ipinfo.io/$ip/json" 2>/dev/null || true)"
if [ -n "$geo" ] && command -v jq >/dev/null; then
  printf '%s' "$geo" | jq -r '"org: \(.org // "?")\nlocation: \(.city // "?"), \(.region // "?"), \(.country // "?")"' 2>/dev/null || true
fi
# Warn only if the caller passes NODE_IP (the host's own public IP) and we match
# it — that means egress is bypassing the VPN tunnel.
if [ -n "${NODE_IP:-}" ] && [ "$ip" = "$NODE_IP" ]; then
  echo "WARNING: egress IP equals NODE_IP ($NODE_IP) — VPN egress is NOT active" >&2
fi
