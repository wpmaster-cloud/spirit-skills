---
name: webhooks
requires: curl, jq
description: >
  Send messages to Slack or Discord from the agent using nothing but curl + jq —
  no SDK, no bot gateway. Use whenever the user wants the agent to post to a Slack
  channel or a Discord channel, notify a team, send an alert / build-status /
  deploy notification, "let the channel know when done", "tell the discord", or
  "ping the team on slack". Slack supports an Incoming Webhook (one preset channel)
  or a Bot token (chat.postMessage, any channel) and auto-selects whichever is
  configured; Discord uses an Incoming Webhook and auto-chunks past its 2000-char
  limit. The chat-notification counterpart to the `telegram` and `whatsapp` skills.
  Trigger phrases: "slack", "post to slack", "notify the team", "send to #channel",
  "slack alert", "discord", "post to discord", "discord webhook", "notify discord",
  "ping the channel", "let slack/discord know", "message us on slack".
---

# webhooks — post to Slack or Discord with curl

One skill, two destinations. Both are pure `curl + jq` — the simplest possible
integration, no SDK and no persistent connection.

```
skills/webhooks/
├── SKILL.md
├── config.env.example        # holds both providers' creds; copy to webhooks/config.env
└── scripts/
    ├── slack_send.sh
    └── discord_send.sh
```

Paths are relative to the **workspace root**. Both scripts auto-source
`webhooks/config.env` (override with `SLACK_CONFIG` / `DISCORD_CONFIG`); env vars
of the same name always win. Keep `webhooks/config.env` out of git — it holds
secret URLs/tokens.

## Slack

Two transports, auto-selected by which credential is present (bot token wins):

- **Incoming Webhook** — a URL bound to one channel, zero OAuth scopes. Best for
  firing alerts into `#ops`. Set `SLACK_WEBHOOK_URL`.
- **Bot token** (`xoxb-…`) — calls `chat.postMessage`, so you can target any
  channel at send time and get the message `ts` back. Needs the `chat:write`
  scope and the bot `/invite`d to the channel. Set `SLACK_BOT_TOKEN` and a default
  `SLACK_CHANNEL` (e.g. `#alerts`), or pass `--channel` per message.

```bash
send=skills/webhooks/scripts/slack_send.sh
bash $send "Deploy finished ✅ — 0 failures"
bash $send --channel '#alerts' "build broke on main"     # bot-token mode
echo "$LONG_REPORT" | bash $send --stdin
```

On success prints `sent …`; on failure prints Slack's error (`channel_not_found`,
`not_in_channel`, `invalid_auth`) and exits non-zero. Slack renders *mrkdwn*
(`*bold*`, `` `code` ``, `<url|text>`); plain text is always safe. `--channel`
applies only in bot mode. Rate limit ~1 msg/sec per channel.

## Discord

**Incoming Webhook** only — a single URL that posts into one channel, no bot, no
gateway. In Discord: *Channel → Edit Channel → Integrations → Webhooks → New
Webhook → Copy Webhook URL*. Set `DISCORD_WEBHOOK_URL`.

```bash
send=skills/webhooks/scripts/discord_send.sh
bash $send "Deploy finished ✅"
bash $send --username "spirit-bot" "build broke on main"   # override displayed name
echo "$LONG_REPORT" | bash $send --stdin                    # auto-chunked at 1900 chars
```

Discord renders standard Markdown (`**bold**`, `` `code` ``, ```` ```fenced``` ````,
`> quote`). **2000-char hard limit** per message — the script splits longer bodies
into ~1900-char chunks sent in order; for genuinely large output post a short
summary and link the full text elsewhere. One webhook = one channel; HTTP 429 with
`retry_after` on rate limit — don't tight-loop.

## Generic webhooks

For any other "POST JSON to a URL" target, no script is needed — just curl:

```bash
curl -fsS -X POST -H 'Content-type: application/json' \
  --data "$(jq -nc --arg t "$MSG" '{text:$t}')" "$SOME_WEBHOOK_URL"
```

## Notes

- Pair with **cron** for scheduled posts/digests, or call a send script at the end
  of a long task to notify on completion/failure.
- One webhook = one channel. For several channels, create several webhooks and
  select with the matching `*_WEBHOOK_URL` (or a per-call config).
