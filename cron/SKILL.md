---
name: cron
description: >
  Schedule recurring or one-time work with cron — including waking yourself or
  other agents on a schedule. Use whenever the user says "every day/hour",
  "periodically", "keep checking", "remind me", "schedule", "at 9am", or wants
  an agent to have a standing task that survives between conversations. Covers
  reading/adding/removing crontab entries safely, the agent wake pattern,
  self-removing one-time jobs, and cron's environment gotchas.
requires: crontab
---

# Cron

Two worlds, pick by where you are:

- **On a host** (macOS, a Linux server) → `crontab`. The rest of this skill.
- **In a container / pod** (the usual spirit deployment) → **there is no cron
  daemon, and `crontab` cannot run** as the non-root agent user: busybox
  `crontab` needs to be setuid root, privilege escalation is blocked, and
  nothing would fire the entry anyway. Don't fight it — use **container loop
  mode** below. (Symptom that you're here: `crontab: must be suid to work
  properly`.)

## Rules

- **Tag every entry you create** with a trailing marker comment
  `# spirit-agent:<job-name>` so it can be listed and removed exactly, without
  touching entries owned by the user or other tools.
- Never replace the whole crontab blind: always start from `crontab -l` and
  filter, so existing entries survive.
- Cron runs with a minimal environment: no PATH from your shell, no exported
  keys. Use absolute paths and `cd` into the agent folder; the API key must be
  reachable (`LLM_API_KEY` in the environment, or set it inline in the cron
  line).

## Recipes

```bash
# List everything / only your entries
crontab -l 2>/dev/null
crontab -l 2>/dev/null | grep -F '# spirit-agent:'

# Add an entry (append, keep the rest)
( crontab -l 2>/dev/null
  printf '%s\n' '*/15 * * * * cd /abs/path/agents/researcher && ./agent.sh "Wake: continue your standing task. If nothing pending, reply exactly: idle." >> cron.log 2>&1 # spirit-agent:researcher-wake'
) | crontab -

# Remove one of your entries by its marker
crontab -l 2>/dev/null | grep -vF '# spirit-agent:researcher-wake' | crontab -

# One-time job: the line removes itself after running
( crontab -l 2>/dev/null
  printf '%s\n' '30 9 14 6 * cd /abs/path && ./agent.sh "send the report" >> cron.log 2>&1; crontab -l | grep -vF "# spirit-agent:once-report" | crontab - # spirit-agent:once-report'
) | crontab -
```

## Agent wake pattern

- A wake is just a one-shot run: `cd <agent folder> && ./agent.sh "Wake: ..."`.
- If a wake fires while the agent is already running, it exits 75 (session
  busy) — harmless; the next wake catches up. Queued messages in the session
  are processed on whichever run comes next.
- Stagger fleets so they do not hit the API at the same instant: `*/15` for
  one agent, `2-59/15` for the next, `4-59/15` after that.
- Keep wake prompts cheap: the agent's system prompt should say to reply
  exactly `idle` when nothing is pending, so an idle wake costs one model call.

## Memory maintenance schedule (notes / memory skills)

The durable-memory skills are built to be *maintained* on a schedule, not just
written to — otherwise the store rots into an unsearchable junk drawer. Recommended
cadence (tune to the agent):

| Skill | Distill (1–2×/day) | Hygiene (weekly) |
|-------|--------------------|------------------|
| `notes`  | `notes.sh reflect` — recent events → durable notes + `MEMORY.md` | `notes.sh audit` → **defrag with judgment** (split/merge/prune, *archive never delete*) |
| `memory` | `memory.sh consolidate` — episodes → facts | `memory.sh forget` — decay-prune low-value memories |

**`reflect`/`consolidate` and `forget` are plain script calls** (they do the LLM
distill themselves), so a direct cron line / loop tick works — but they need the
agent's `BASE_URL`/`LLM_API_KEY` in env. **Defrag is reasoning-heavy** (it splits
and merges with judgment), so drive it through an *agent wake*, not a bare script
call.

```bash
# Host crontab — distill twice daily, hygiene weekly (env-key must be reachable):
0 */12 * * * cd /abs/agent && NOTES_DIR=$PWD/notes bash skills/notes/scripts/notes.sh reflect >> logs/mem.log 2>&1 # spirit-agent:notes-reflect
0 4 * * 0    cd /abs/agent && ./agent.sh "Maintenance: run skills/notes audit, then defrag with judgment (archive, never delete), and commit the vault." >> logs/mem.log 2>&1 # spirit-agent:notes-defrag
```

In a **pod** (no crontab — use the container loop below or `ops/agent.yaml`'s
wake-loop): fold a maintenance tick into the loop, e.g. every 12h run
`notes.sh reflect`, and once a week fire a defrag *wake* so the agent does the
judgment work. Always **commit + push the vault** after maintenance so it
survives the ephemeral pod.

## Container loop mode (no crontab)

In a pod the durable scheduler is a `while true; … sleep N` loop, not crontab.
Two things make it work *correctly* — get both or it bites you:

1. **Survive restarts.** A loop you launch as a detached child of a run dies
   with that run and never comes back on the next pod start (the pod's command
   is `tail -f /dev/null`, which doesn't relaunch it). For a loop that truly
   persists, put it in the pod's `command:` (see the commented wake-loop in
   `ops/agent.yaml`) so the container runtime supervises and restarts it. A loop
   started by hand inside a running pod is **best-effort until the next restart**
   — say so when you set one up.
2. **Register it so the control plane can see it.** The control plane only knows
   the one pid holding the session lock (the in-flight run); a standing loop is
   otherwise invisible — you can't see it, can't tell it's accidentally doubled,
   can't stop it from the UI. Drop a pidfile at
   `<agent>/.admin/daemons/<name>.pid` (first line: the pid; optional second
   line: a human label). The UI lists every registered daemon, flags dead ones,
   and gives a Stop button.

Self-registering, single-instance, signal-clean loop — the pattern to copy:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."                 # the agent folder
name="telegram-poll"                    # one word; becomes the daemon's UI name
reg=".admin/daemons/$name.pid"
mkdir -p .admin/daemons logs

# single-instance guard: if a live pid is already registered, bow out (this is
# what stops the accidental double loop)
if [ -f "$reg" ] && kill -0 "$(head -1 "$reg" 2>/dev/null)" 2>/dev/null; then
  exit 0
fi
printf '%s\n%s\n' "$$" "bash bin/${name}.sh — every 5m" > "$reg"
trap 'rm -f "$reg"' EXIT INT TERM       # de-register on exit, including SIGTERM

while true; do
  ./bin/${name}_wake.sh >> "logs/$name.log" 2>&1 || true
  sleep 300 & wait $!                    # background sleep + wait, so a SIGTERM
done                                     # from the UI's Stop fires the trap NOW,
                                         # not after the current sleep ends
```

- `sleep 300 & wait $!` (not a bare `sleep 300`) is what makes the UI's **Stop**
  prompt: a trap can't interrupt a foreground `sleep`, so a bare sleep would
  ignore SIGTERM for up to the whole interval.
- **Never hardcode `LLM_API_KEY` (or any secret) into the loop or its wake
  script** — it's already in the pod env; just let the child inherit it. A key
  written to a file is a leak that outlives the run.
- Verify it registered: `cat .admin/daemons/<name>.pid` and check the agent's
  card in the UI — it shows a `⟳ tasks` chip; the agent page lists each daemon
  with a Stop button.

## Verify and debug

```bash
crontab -l | tail -n 5            # entry is really there
tail -n 40 /abs/path/cron.log     # what the last wakes did
```

- macOS: cron may need Full Disk Access (System Settings > Privacy) to read
  the agent folder; if wakes silently do nothing, check `cron.log` exists at
  all.
- Minute granularity is the floor. For "every 30 seconds" use the container
  loop mode instead.
