---
name: rss-monitor
requires: python3
description: >
  Watch RSS/Atom feeds and surface only what's new since the last check, with
  per-feed memory so each item is reported exactly once. Use whenever the user
  wants the agent to monitor a blog/news/release/changelog/status feed, "tell me
  when X publishes something new", track a podcast or YouTube channel feed, poll a
  site for updates on a schedule, or build a digest of recent feed items. Pairs
  with the `cron` skill for a standing watch and any comms skill (`telegram`,
  `webhooks`, `email`, `whatsapp`) to push the new items. Trigger phrases:
  "rss", "atom feed", "monitor this feed", "watch for new posts", "notify me when
  <site> publishes", "new releases", "changelog updates", "subscribe to", "poll
  this feed", "feed digest".
---

# rss-monitor — report only new feed items

`scripts/feed.py` fetches an RSS 2.0 or Atom feed (pure Python stdlib — no pip
installs), parses items robustly across both formats, and prints only the items it
hasn't seen before. It remembers seen item ids per feed under a state dir, exactly
like the `telegram` skill's offset memory: each item surfaces **once** across runs,
which is what makes a cron-driven watcher not spam you with the whole feed every
time.

```
skills/rss-monitor/
└── scripts/feed.py
```

Paths are relative to the **workspace root**. State is written under
`rss/state/` (keep it under `/work` so it survives the write-jail and commits with
the agent).

## Usage

```bash
feed=skills/rss-monitor/scripts/feed.py

# new items since last check (consumes: marks them seen). TSV: date <tab> title <tab> link
python3 $feed https://example.com/blog/feed.xml

# as JSON (title/link/date/summary/id) for programmatic use:
python3 $feed https://example.com/feed.xml --json

# look without consuming (don't persist the seen-marks):
python3 $feed https://example.com/feed.xml --peek

# ignore memory and dump everything currently in the feed:
python3 $feed https://example.com/feed.xml --all

# forget this feed's memory (re-reports the backlog next run):
python3 $feed https://example.com/feed.xml --reset

# cap how many new items you take this run:
python3 $feed https://example.com/feed.xml --limit 5
```

**Consume semantics:** a normal run prints the new items *and* records them as
seen, so the next run won't repeat them — mirror of `telegram`'s `tg_read.sh`. Use
`--peek` when you just want to look, `--reset` to start over. First run on a feed
reports everything (nothing is seen yet) — run once with `--peek`/`--reset` first
if you only want *future* items.

## The standing-watch pattern (cron + a comms skill)

Give the agent a wake on a schedule (the **cron** skill, or the wake-loop in
`ops/agent.yaml`). Each firing checks the feed and pushes anything new:

```cron
*/15 * * * * cd /abs/path/agents/feed-watcher && ./agent.sh "Wake: run python3 skills/rss-monitor/scripts/feed.py https://example.com/feed.xml. For each new item, send a one-line Slack message with bash skills/webhooks/scripts/slack_send.sh '<title> — <link>'. If there are none, reply exactly: idle." >> cron.log 2>&1 # spirit-agent:feed-watch
```

Because the agent has **one session**, the watcher accumulates context naturally
and `compact_session` keeps it bounded. Bake the standing instructions (which
feeds, how to format, "never repeat an item") into the system prompt so the
per-wake message stays short — see the `agent-workshop` skill.

## Notes

- Handles both RSS (`<item>`: title/link/guid/pubDate) and Atom (`<entry>`:
  title/link@href/id/updated), and ignores XML namespaces so Atom and
  podcast/YouTube feeds parse cleanly.
- Item identity is the `guid`/`id`, else the link, else a hash of the item — so
  feeds without guids still de-duplicate sensibly.
- The state file caps stored ids (most-recent 2000) so it can't grow without
  bound. It's plain JSON under `rss/state/` — safe to commit, inspect, or delete.
- Network egress follows the agent's normal forced-VPN path; a feed behind an
  IP-allowlist may not be reachable (check with **net-diag**).
