#!/usr/bin/env bash
# DNS lookups and cross-resolver propagation checks (dig). Usage:
#   dns.sh NAME                 # A/AAAA/CNAME/MX/NS/TXT summary
#   dns.sh NAME TYPE            # a single record type
#   dns.sh NAME TYPE --propagate    # compare answers across public resolvers
set -euo pipefail
command -v dig >/dev/null || { echo "dns.sh: dig not found (apk add bind-tools)" >&2; exit 127; }

name="${1:?usage: dns.sh NAME [TYPE] [--propagate]}"; shift
type=""; prop=0
for a in "$@"; do
  case "$a" in
    --propagate) prop=1;;
    -*) echo "dns.sh: unknown flag: $a" >&2; exit 2;;
    *) type="$a";;
  esac
done

if [ -z "$type" ]; then
  any=0
  for t in A AAAA CNAME MX NS TXT; do
    ans="$(dig +short "$name" "$t" 2>/dev/null || true)"
    if [ -n "$ans" ]; then echo "== $t =="; printf '%s\n' "$ans"; any=1; fi
  done
  [ "$any" = 1 ] || { echo "dns.sh: no records found for $name" >&2; exit 1; }
  exit 0
fi

if [ "$prop" = 1 ]; then
  echo "== $name $type across resolvers =="
  for r in 1.1.1.1 8.8.8.8 9.9.9.9 208.67.222.222; do
    printf '%-16s %s\n' "$r" "$(dig +short "@$r" "$name" "$type" 2>/dev/null | paste -sd, - || echo '(no answer)')"
  done
else
  dig +noall +answer "$name" "$type"
fi
