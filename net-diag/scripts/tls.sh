#!/usr/bin/env bash
# Inspect a TLS endpoint's certificate: subject/issuer/serial, validity window,
# days-to-expiry, SANs, and the negotiated protocol/cipher. Usage:
#   tls.sh HOST                 # defaults to :443
#   tls.sh HOST:PORT
#   tls.sh --servername SNI HOST:PORT
set -euo pipefail
command -v openssl >/dev/null || { echo "tls.sh: openssl not found" >&2; exit 127; }

sni=""
if [ "${1:-}" = "--servername" ]; then sni="${2:?--servername needs a value}"; shift 2; fi
hostport="${1:?usage: tls.sh HOST[:PORT]}"
host="${hostport%%:*}"; port="${hostport##*:}"; [ "$port" = "$host" ] && port=443
sni="${sni:-$host}"

raw="$(echo | openssl s_client -connect "$host:$port" -servername "$sni" 2>/dev/null)" \
  || { echo "tls.sh: cannot connect to $host:$port" >&2; exit 1; }
cert="$(printf '%s' "$raw" | openssl x509 2>/dev/null)" \
  || { echo "tls.sh: no certificate returned by $host:$port" >&2; exit 1; }

echo "== $host:$port (SNI: $sni) =="
printf '%s\n' "$cert" | openssl x509 -noout -subject -issuer -serial 2>/dev/null

echo "-- validity --"
printf '%s\n' "$cert" | openssl x509 -noout -dates 2>/dev/null
end="$(printf '%s\n' "$cert" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)"
if end_epoch="$(date -d "$end" +%s 2>/dev/null)"; then
  days=$(( (end_epoch - $(date +%s)) / 86400 ))
  echo "days to expiry: $days"
  [ "$days" -lt 0 ] && echo "  *** EXPIRED ***"
  { [ "$days" -ge 0 ] && [ "$days" -lt 14 ]; } && echo "  *** EXPIRES SOON ***"
fi

echo "-- subjectAltName --"
printf '%s\n' "$cert" | openssl x509 -noout -ext subjectAltName 2>/dev/null | sed '1d;s/^ *//' || true

echo "-- protocol --"
printf '%s\n' "$raw" | grep -E '^ *(Protocol|Cipher) *:' | sed 's/^ *//' | sort -u
