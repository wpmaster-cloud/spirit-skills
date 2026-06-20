#!/usr/bin/env bash
# Send a Slack message. Transport is auto-selected:
#   SLACK_BOT_TOKEN  → chat.postMessage (any channel via --channel/SLACK_CHANNEL)
#   SLACK_WEBHOOK_URL → Incoming Webhook (its one preset channel)
# Usage:
#   slack_send.sh "text"
#   slack_send.sh --channel '#alerts' "text"     # bot-token mode
#   echo "$BODY" | slack_send.sh --stdin
set -euo pipefail
cfg="${SLACK_CONFIG:-webhooks/config.env}"; [ -f "$cfg" ] && { set -a; . "$cfg"; set +a; }

channel="${SLACK_CHANNEL:-}"; stdin=0; text=""
while [ $# -gt 0 ]; do
  case "$1" in
    --channel) channel="${2:?--channel needs a value}"; shift 2;;
    --stdin) stdin=1; shift;;
    --) shift; text="$*"; break;;
    *) text="$1"; shift;;
  esac
done
[ "$stdin" = 1 ] && text="$(cat)"
[ -n "$text" ] || { echo "slack_send.sh: empty message" >&2; exit 2; }

if [ -n "${SLACK_BOT_TOKEN:-}" ]; then
  [ -n "$channel" ] || { echo "slack_send.sh: bot mode needs --channel or SLACK_CHANNEL" >&2; exit 2; }
  payload="$(jq -nc --arg c "$channel" --arg t "$text" '{channel:$c, text:$t}')"
  resp="$(curl -fsS -X POST https://slack.com/api/chat.postMessage \
      -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
      -H 'Content-type: application/json; charset=utf-8' --data "$payload")" \
    || { echo "slack_send.sh: request failed" >&2; exit 1; }
  if [ "$(printf '%s' "$resp" | jq -r '.ok')" = true ]; then
    echo "sent: channel=$(printf '%s' "$resp" | jq -r '.channel') ts=$(printf '%s' "$resp" | jq -r '.ts')"
  else
    echo "slack_send.sh: API error: $(printf '%s' "$resp" | jq -r '.error // "unknown"')" >&2; exit 1
  fi
elif [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
  payload="$(jq -nc --arg t "$text" '{text:$t}')"
  if curl -fsS -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK_URL" >/dev/null; then
    echo "sent (webhook)"
  else
    echo "slack_send.sh: webhook POST failed" >&2; exit 1
  fi
else
  echo "slack_send.sh: no credentials (set SLACK_WEBHOOK_URL or SLACK_BOT_TOKEN)" >&2; exit 2
fi
