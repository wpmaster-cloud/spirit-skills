---
name: cron
description: >
  Schedule recurring or one-time work — waking yourself on a schedule by writing
  a cron definition file. Use whenever the user says "every day/hour",
  "periodically", "keep checking", "remind me", "schedule", "at 9am", or wants a
  standing task that survives between conversations. Covers the _cronjobs/ JSON
  format, ephemeral vs. continuing sessions, staggering, and why crontab is not
  the answer here.
requires: jq
---

# Scheduling (cron)

**You schedule yourself by writing a file. Never use `crontab`.**

`crontab` is unavailable here and cannot be made to work: there is no cron
daemon in the container, and busybox `crontab` needs to be setuid root while
privilege escalation is blocked. (Symptom: `crontab: must be suid to work
properly`.) Nothing would fire the entry even if it saved.

Instead, the spirit server runs an **in-process scheduler** that ticks once a
minute and fires any due job it finds. You opt in by dropping a JSON file in
`_cronjobs/` in your own folder — no API call, no privileges, no daemon.

## The one recipe

```bash
mkdir -p _cronjobs
cat > _cronjobs/daily-review.json <<'JSON'
{
  "id": "daily-review",
  "schedule": "0 7 * * *",
  "session": "session.jsonl",
  "prompt": "Review yesterday's changes and write a summary note.",
  "ephemeral": true,
  "enabled": true
}
JSON
```

That's the whole mechanism. The scheduler picks it up on the next tick.

## The fields

| Field | Meaning |
|---|---|
| `id` | Job identity. **Match the filename** (`<id>.json`) — the UI and the delete path key off it. |
| `schedule` | Standard **5-field** cron (`min hour dom month dow`). Minute granularity is the floor. |
| `session` | Which conversation to wake, e.g. `session.jsonl`. A **bare filename** — the server resolves it under `_sessions/` itself. |
| `prompt` | Queued as a user message each run. **Required for the run to do anything** — a wake with nothing pending is a no-op. |
| `ephemeral` | `true` = reset the session to its seed snapshot each run (fresh context, no memory growth). `false` = one conversation that accumulates. |
| `enabled` | `false` pauses the job without deleting it. |
| `label` | Optional human name for the UI. |

Choosing `ephemeral`:

- **`true` for repeatable chores** — a digest, a health check, a poll. Every run
  starts identical and clean, and the session never grows without bound. This is
  what you want most of the time.
- **`false` for a genuine ongoing thread** where each run should remember the
  last. Watch the size; it grows forever otherwise.

## What actually happens on a tick

1. The scheduler scans the vault for `_cronjobs/*.json` once a minute.
2. For each **enabled** job whose expression matches the current minute:
   ephemeral jobs get their session reset to its seed snapshot, a non-empty
   `prompt` is appended as a user message, then `agent.sh --run` is exec'd
   detached in your folder.
3. Double-fires are guarded (keyed by job file + minute), and the session lock
   prevents overlap: if the session is already running, the job is skipped this
   tick rather than stacking.

## The honest limits — read before promising a schedule

- **The server must be running AND unlocked.** The LLM key is captured at unlock,
  so a locked vault fires nothing. After any restart, **nothing runs until a
  human unlocks it**. A cron job is best-effort, not a guarantee — don't promise
  a scheduled action will definitely have happened; check that it did.
- **It is not a timer you can trust to the second.** Minute granularity, and a
  busy session skips its tick.
- **A silent job is a lie you tell yourself.** If the work matters, have the
  prompt report somewhere you'll see (a note, the `telegram`/`webhooks` skill)
  on failure — not just on success.

## Managing jobs

```bash
ls _cronjobs/*.json                                   # what am I signed up for?
jq -r '"\(.id): \(.schedule) enabled=\(.enabled) ephemeral=\(.ephemeral)"' _cronjobs/*.json

jq '.enabled = false' _cronjobs/daily-review.json > .t && mv .t _cronjobs/daily-review.json  # pause
rm _cronjobs/daily-review.json                        # remove for good
```

The app's clock icon is the same thing with a UI (it also drops the job's seed
snapshot when it deletes). Editing the file by hand is fully supported.

## Wake prompts that don't waste money

This runs unattended, possibly hundreds of times. Make it **cheap when idle and
loud when broken**:

- Keep the prompt idempotent — it will run again, and a job that appends
  something every tick creates a mess by Friday.
- Instruct an early exit: "…if nothing is pending, reply exactly: `idle`." An
  idle wake should cost one model call, not twenty.
- **Stagger** multiple jobs so they don't all hit the API on the same minute:
  `*/15` for one, `2-59/15` for the next, `4-59/15` after that.
- `0 7 * * *` fires at 07:00 **UTC** unless the container says otherwise —
  confirm with `date -u` rather than assuming local time.

## Don't hand-roll a polling daemon

It is tempting to write `while true; do …; sleep 60; done &` when a schedule
seems not to fire. Don't:

- It **dies on every pod restart** and never comes back — nothing supervises it,
  and it isn't in the deployment. It stops silently and you keep believing it runs.
- It is **invisible**: not in `_cronjobs/`, not in the UI, not in any list. The
  next person to look (including future-you) has no idea it exists.
- Its memory counts against the **server's** memory limit, because your commands
  run inside the server's pod. A loop that spawns real work can OOM the whole app.

If a job seems not to fire, the answer is almost always that **the vault is
locked** (see the limits above) or `enabled` is `false` — not that the scheduler
is broken. Check those first:

```bash
jq -r '.enabled' _cronjobs/<id>.json   # is it even on?
tail -n 20 _logs/cron.log 2>/dev/null  # did it fire and fail?
tail -n 40 _logs/agent.log             # what did the run actually do?
```

## Memory maintenance schedule (notes / memory skills)

The durable-memory skills are built to be *maintained* on a schedule, not just
written to — otherwise the store rots into an unsearchable junk drawer.

| Skill | Distill (1–2×/day) | Hygiene (weekly) |
|-------|--------------------|------------------|
| `notes`  | `notes.sh reflect` — recent events → durable notes + `MEMORY.md` | `notes.sh audit` → **defrag with judgment** (split/merge/prune, *archive never delete*) |
| `memory` | `memory.sh consolidate` — episodes → facts | `memory.sh forget` — decay-prune low-value memories |

Both run as agent wakes here — the prompt is the interface:

```bash
cat > _cronjobs/notes-reflect.json <<'JSON'
{
  "id": "notes-reflect", "schedule": "0 */12 * * *", "session": "session.jsonl",
  "prompt": "Memory upkeep: run `bash skills/notes/scripts/notes.sh reflect` to distill recent events into durable notes, then reply with one status line.",
  "ephemeral": true, "enabled": true
}
JSON
```

**Defrag is reasoning-heavy** (it splits and merges with judgment), so drive it
through a wake with a real prompt rather than a bare script call:

```bash
cat > _cronjobs/notes-defrag.json <<'JSON'
{
  "id": "notes-defrag", "schedule": "0 4 * * 0", "session": "session.jsonl",
  "prompt": "Weekly memory hygiene: run skills/notes audit, then defrag with judgment (archive, never delete). Report what you merged, split, or archived.",
  "ephemeral": true, "enabled": true
}
JSON
```

Your notes live in the vault, which is on persistent storage and backed up — you
do not need to commit them to git to keep them (use `git-and-github` when you
want *history*, not for survival).
