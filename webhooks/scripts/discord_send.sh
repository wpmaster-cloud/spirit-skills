#!/usr/bin/env bash
# Send a message to a Discord channel via an Incoming Webhook (no bot needed).
# Auto-chunks bodies over Discord's 2000-char limit. Usage:
#   discord_send.sh "text"
#   discord_send.sh --username "spirit" "text"
#   echo "$BODY" | discord_send.sh --stdin
set -euo pipefail
cfg="${DISCORD_CONFIG:-webhooks/config.env}"; [ -f "$cfg" ] && { set -a; . "$cfg"; set +a; }
: "${DISCORD_WEBHOOK_URL:?set DISCORD_WEBHOOK_URL (Channel → Edit → Integrations → Webhooks)}"

user="${DISCORD_USERNAME:-}"; stdin=0; text=""
while [ $# -gt 0 ]; do
  case "$1" in
    --username) user="${2:?--username needs a value}"; shift 2;;
    --stdin) stdin=1; shift;;
    --) shift; text="$*"; break;;
    *) text="$1"; shift;;
  esac
done
[ "$stdin" = 1 ] && text="$(cat)"
[ -n "$text" ] || { echo "discord_send.sh: empty message" >&2; exit 2; }

send_chunk() {
  local body="$1" payload
  if [ -n "$user" ]; then payload="$(jq -nc --arg c "$body" --arg u "$user" '{content:$c, username:$u}')"
  else payload="$(jq -nc --arg c "$body" '{content:$c}')"; fi
  curl -fsS -X POST -H 'Content-type: application/json' --data "$payload" \
       "${DISCORD_WEBHOOK_URL}?wait=true" >/dev/null \
    || { echo "discord_send.sh: webhook POST failed" >&2; return 1; }
}

# Chunk to 1900 chars (under the 2000 hard limit, leaving headroom).
remaining="$text"
while [ -n "$remaining" ]; do
  chunk="${remaining:0:1900}"; remaining="${remaining:1900}"
  send_chunk "$chunk"
done
echo "sent (discord webhook)"
