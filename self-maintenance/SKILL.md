---
name: self-maintenance
description: >
  Health-check and repair this agent. Use when a session file fails to parse or
  the agent crashed mid-run, when the session has grown large, when backups or
  temp files pile up, for a periodic "checkup" wake, or whenever the user says
  the agent is broken, stuck, corrupt, too big, or needs cleaning. Covers:
  validating a session, repairing torn lines and broken tool-call pairs after a
  crash, pruning compaction backups, and removing crash droppings.
requires: jq
---

# Self-maintenance

The session file is the agent's only state, so "fix the agent" almost always
means "fix or shrink a session file".

## Where things live

Sessions live in **`_sessions/`**, not at the folder root:

```
_sessions/session.jsonl          # the default conversation
_sessions/session-2.jsonl        # more conversations — NORMAL, not a fault
_sessions/session.jsonl.lock/    # present = that session is running right now
_logs/agent.log                  # run output
tool_outputs/<id>.json           # offloaded tool results — compacted sessions point HERE
```

**An agent may hold several sessions on purpose** — each is an independent
conversation with its own memory and its own run lock, and the app lists them.
Never "clean up" extra sessions; you would be deleting real conversations.
(The runtime only refuses to start on ambiguity when nothing tells it which
session to use — the app always passes `SESSION_FILE=_sessions/<name>`, so that
case does not arise here.)

Pick the session you were asked about, and **never repair one that is running**:

```bash
s=_sessions/session.jsonl                   # or the session you were asked about
[ -d "$s.lock" ] && { echo "session is running; do not touch"; exit 0; }
```

That guard is load-bearing — repairing a live session corrupts the very file
the running agent is appending to. Verify it actually resolves before trusting
it: `ls -d "$s" "$s.lock" 2>/dev/null`.

## Checkup (run this first)

```bash
wc -c "$s"                                    # > ~400000 bytes: compact soon
jq -es 'length' "$s" >/dev/null 2>&1 && echo OK || echo CORRUPT
ls "$s".bak.* 2>/dev/null | wc -l             # compaction backups piling up?
ls .cmd-output.* .cmd-status.* .llm-payload.* .llm-response.* .llm-summarize.* \
   .session-compact.* .session-offload.* 2>/dev/null   # crash droppings?
du -sh tool_outputs 2>/dev/null               # offloaded results (do NOT delete)
```

If the session is OK but large, call your **`compact_context`** tool — that is
the real tool name, and it takes an optional `focus` naming what must survive
verbatim. (For *another* agent, wake it and ask it to compact itself.)

## Repair a corrupt session

A crash mid-append leaves a torn last line. The replay tolerates this (it
silently skips unparseable lines), but a skipped line can orphan a tool-call
pair, and the API rejects the whole session when pairs don't match. Keep
evidence, drop unparseable lines, then fix tool-call pairing:

```bash
cp -- "$s" "$s.corrupt.$(date -u +%Y%m%dT%H%M%SZ)"
jq -cR 'fromjson?' "$s" > .repair && mv .repair "$s"
```

The API rejects a session whose assistant `tool_calls` and `tool` results do
not pair up, so after dropping lines, check both directions:

```bash
# tool calls that lost their result -> answer each one synthetically
jq -r -s '([.[] | select(.role=="assistant") | .tool_calls[]?.id]
           - [.[] | select(.role=="tool") | .tool_call_id])[]' "$s" \
| while IFS= read -r id; do
    jq -nc --arg id "$id" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{kind:"message", created_at:$t, role:"tool", tool_call_id:$id,
        content:"{\"error\":\"tool result lost in crash repair\"}"}' >> "$s"
  done

# tool results that lost their call -> remove them
jq -c -s '[.[] | select(.role=="assistant") | .tool_calls[]?.id] as $asked
  | .[] | select(.role != "tool" or ([.tool_call_id] | inside($asked)))' \
  "$s" > .repair && mv .repair "$s"
```

> The runtime already synthesizes stub results for unanswered tool calls at
> replay time, so a session that merely got interrupted usually needs no repair
> at all. Reach for this only when `jq -es` says CORRUPT.

Verify, then delete the `.corrupt.*` evidence file once a real run succeeds:

```bash
jq -es 'length' "$s" >/dev/null && echo repaired
```

## Routine cleanup (only when idle)

```bash
# keep the 3 newest compaction backups of this session, drop the rest
ls -t "$s".bak.* 2>/dev/null | tail -n +4 | while IFS= read -r f; do rm -f -- "$f"; done

# crash droppings from interrupted runs (always transient; a live run recreates them)
rm -f .cmd-output.* .cmd-status.* .llm-payload.* .llm-response.* .llm-summarize.* \
      .session-compact.* .session-offload.*

# oversized log: keep the tail, don't delete
tail -n 5000 _logs/agent.log > _logs/agent.log.tmp && mv _logs/agent.log.tmp _logs/agent.log
```

**Never delete:** a session file, a `.bak.*` backup, `tool_outputs/` (a compacted
session's inline pointers reference those paths — deleting them destroys memory
you can still read back), or a **live** lock. A stale lock whose owner pid is
dead is taken over automatically on the next run — do not remove lock
directories by hand.

## Make it periodic

Schedule a standing checkup by writing a cron definition — **never `crontab`**,
which is unavailable here (see the `cron` skill):

```bash
mkdir -p _cronjobs
cat > _cronjobs/weekly-checkup.json <<'JSON'
{
  "id": "weekly-checkup",
  "schedule": "10 6 * * 1",
  "session": "session.jsonl",
  "prompt": "Weekly checkup: run the self-maintenance skill checkup and cleanup on yourself; repair only if corrupt. Reply with one status line.",
  "ephemeral": true,
  "enabled": true
}
JSON
```
