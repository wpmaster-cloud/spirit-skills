---
name: agent-workshop
requires: jq
description: >
  Create, command, and supervise more spirit agents. Use whenever the user wants
  to spawn a subagent or helper agent, delegate or parallelize work across
  agents, send a task or message to another agent, read another agent's progress
  or replies, or schedule an agent. Trigger phrases: "subagent", "another
  agent", "spawn an agent", "delegate", "tell agent X", "check on the agent".
---

# Agent Workshop

How to build, talk to, and supervise agents like this one. Read this fully
before spawning or messaging an agent; the invariants at the end prevent
corrupted sessions.

## Anatomy: an agent is a folder

```
researcher/
├── index.md              # folder node; frontmatter `agent: true` lights up the app's chat panel
├── agent.sh              # the runtime (a copy of yours)
├── .env                  # OPTIONAL per-agent secrets/model — dotfile, never in the tree
├── _sessions/            # session.jsonl, session-2.jsonl, …  ← the agent's MEMORY
│   └── session.jsonl     # line 1 = system prompt = its identity
├── _logs/                # agent.log, cron.log
├── _cronjobs/            # <id>.json schedules
└── tool_outputs/         # offloaded large tool results
```

Facts you rely on:

- **The jail is hierarchical, so nest your children.** Your reads and writes are
  confined to your folder and everything *beneath* it. A sub-agent you create
  beneath you is one you can read, fix, and supervise. An agent created outside
  your folder is invisible to you — you cannot supervise it at all.
- **Sessions live in `_sessions/`.** This is a server convention, and it is the
  single most common way to get this wrong (see *Give work*). A folder may hold
  **several** sessions on purpose — each is an independent conversation with its
  own memory and its own run lock, and the app lists them. That is a feature,
  not a fault.
- **Line 1 of the session file is the system prompt.** That is the whole identity
  mechanism — there is no config object, no personality store. To change what an
  agent is, rewrite line 1. To give it amnesia, delete the file.
- Config comes from the environment: `AGENT_NAME`, `MODEL`, `BASE_URL`,
  `LLM_API_KEY`, `MAX_TURNS`, `COMMAND_TIMEOUT_SEC`, `COMMAND_MAX_OUTPUT_BYTES`,
  `CONTEXT_COMPACT_TOKENS`, `SESSION_FILE`. If `BASE_URL`/`MODEL` are unset they
  are auto-detected from the API key's prefix (OpenAI, Anthropic, OpenRouter,
  Groq, xAI, NVIDIA, Gemini).
- **`agent.sh` is overwritten from the server's embedded copy on every app-run.**
  Never customize an agent by editing its runtime — the change will silently
  revert. Customize via line 1 of the session, or its `.env`.
- One run per session at a time: while a run is active a `<session>.lock/`
  directory exists next to the session file, and a second run exits **75**
  (busy — retry later). Appending messages is always allowed.

## Spawn a subagent

Create it **beneath your own folder**, and do all four steps — miss the session
and it isn't runnable; miss `agent: true` and it looks like an ordinary folder.

```bash
name=researcher        # lowercase a-z, 0-9 and dashes — agent.sh normalizes AGENT_NAME to this
mkdir -p "$name"/_sessions "$name"/_logs "$name"/_cronjobs
cp -- agent.sh "$name/agent.sh" && chmod +x "$name/agent.sh"   # your copy is the maintained one

# The folder node — `agent: true` is what shows the chat panel in the app.
cat > "$name/index.md" <<EOF
---
type: folder
title: Researcher
agent: true
created_by: "[[$AGENT_NAME]]"
---

Researcher subagent. Managed by [[$AGENT_NAME]].
EOF

# The identity: line 1 of the session IS the system prompt. Author it FRESH.
jq -Rsc --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{kind:"message", created_at:$t, role:"system", content:.}' \
  > "$name/_sessions/session.jsonl" <<'EOF'
You are researcher, an autonomous agent living in one folder of a markdown vault (spirit).
Your folder is your workspace, your home, and your security boundary: you can read and write
here and below, and nothing outside it. Your session file is your entire memory.
Your main tool is run_command: bash, from this folder. Commands time out at 120s and their
output is capped at 64KB — run long jobs detached and poll the log.

Scope: <one sentence — exactly what this agent owns>.
Write your final deliverable to ./outbox.md. Keep chat replies to one short status line.
Reply exactly "idle" when nothing is pending.

Conduct: be concise, lead with the result, verify before claiming done, and report honestly
when something failed. Never print or log secrets.
Whenever you create a node markdown file, add created_by: "[[researcher]]" to its frontmatter.
EOF

# Smoke test — note SESSION_FILE (see below); this is not optional.
cd "$name" && SESSION_FILE=_sessions/session.jsonl ./agent.sh "Confirm you are alive: state your role in one line."
```

**Author the prompt fresh; do not paste your own system prompt in.** A subagent
that inherits your whole identity wanders off-task. Cribbing your *conduct* and
*shell discipline* paragraphs is fine — cribbing your scope is not.

## Give work

**`SESSION_FILE` is mandatory. This is the trap.** Run bare, `agent.sh` looks
for `session.jsonl` at the *folder root*, doesn't find it (sessions live in
`_sessions/`), and **mints a brand-new session at the root** — seeded with the
runtime's minimal fallback prompt, invisible to the app, with none of the
agent's real identity or context. Your task vanishes into a ghost agent.

```bash
# Detached — the normal way. Returns at once; output appends to the child's _logs/agent.log.
cd researcher && SESSION_FILE=_sessions/session.jsonl ./agent.sh -d "Read X, summarize into outbox.md."

# Blocking: only for something genuinely quick. Your own command times out at 120s
# and a child agent routinely takes longer — do not block on real work.
cd researcher && SESSION_FILE=_sessions/session.jsonl ./agent.sh "one quick question"

# Per-run overrides: cheaper model, higher turn budget.
cd researcher && SESSION_FILE=_sessions/session.jsonl MODEL=gpt-5.5-mini MAX_TURNS=30 ./agent.sh -d "task"
```

**Delegate detached, end your turn, and collect on a later turn.** Blocking on a
child is how you burn your 120s and lose the run.

For a durable per-agent override there **is** a persistent file: a `.env` in the
agent's own folder, which `agent.sh` loads before provider detection, so it
beats the vault-wide env. Use it for a per-agent `LLM_API_KEY`/`MODEL`/`BASE_URL`.

```bash
printf 'MODEL=gpt-5.5-mini\n' > researcher/.env    # 0600, dotfile: never in the tree or backups
```

> `.env` is parsed **literally**, not sourced — no variable expansion. `PATH=$PATH:/x`
> writes the literal string `$PATH:/x` and clobbers PATH. One `KEY=VALUE` per line.

Exit **75** means the agent is mid-run. Don't force it — queue a message instead
(next section); queuing never blocks and never collides.

## Communicate through the session file

```bash
sess=researcher/_sessions/session.jsonl
[ -e "$sess" ] || { echo "no session — create it (see Spawn)"; exit 1; }
```

**Queue a task/message** (safe anytime, even mid-run — append only, built with
jq, exact record shape):

```bash
jq -nc \
  --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg c "New instruction: also cover Y. Reply in outbox.md." \
  '{kind:"message", created_at:$t, role:"user", content:$c}' \
  >> "$sess"
```

Queued messages are processed on the agent's **next run** (a cron wake, or any
run you fire later). To deliver now, just fire a wake run — it processes
whatever is queued and appends nothing:

```bash
cd researcher && SESSION_FILE=_sessions/session.jsonl ./agent.sh -d --run
```

**Read its state** (you can read everything beneath you):

```bash
# running or idle? (a live pid in the lock = running; a stale lock reads idle)
kill -0 "$(cat "$sess.lock/pid" 2>/dev/null)" 2>/dev/null && echo running || echo idle

# what it's doing / did
tail -n 40 researcher/_logs/agent.log

# last substantive reply
jq -r -s '[.[] | select(.role == "assistant" and (.content // "") != "")] | last.content' "$sess"

# recent activity, one line per record
tail -n 8 "$sess" | jq -r '.role + ": " + ((.content // "(tool calls)")[0:160])'
```

Exchange large artifacts through files in the agent's folder (`outbox.md`,
`data/*.csv`), not through giant chat messages — a big message is replayed to
the model on *every* future turn.

## Several agents

Ten agents are just ten folders — no daemons, no runtime; an idle agent costs
zero. Keep them **beneath you** so you can supervise them.

- **Delegate by domain, not convenience.** Work touching a domain goes to the
  agent that has that domain's files, context, and secrets.
- **Never delegate a secret in a task string** — it lands in the child's session
  file, which is permanent memory replayed to the model every turn. Put it in the
  child's `.env` instead.
- **Verify before reporting done.** Read the child's log or session tail; don't
  assume success because you dispatched.

Standing/recurring work is scheduled by writing `_cronjobs/<id>.json` in the
agent's folder — see the **`cron`** skill. **Never `crontab`**; it is unavailable
here. Stagger schedules so agents don't all hit the API on the same minute; a
wake that finds the agent busy is skipped harmlessly.

## Invariants (do not break these)

- Build every session line with `jq -nc` / `--rawfile` / `-Rsc`. Never hand-write JSON.
- Foreign sessions: **append only**. Never edit or delete existing lines of
  another agent's session — assistant `tool_calls` lines and their `tool` results
  are linked by id, and breaking a pair makes the API reject the whole session.
- **Always pass `SESSION_FILE=_sessions/<name>`** when running another agent.
- One run per session; respect exit 75 instead of deleting a live lock. A lock
  whose owner pid is dead is taken over automatically — don't clean it by hand.
- A new agent needs: its own folder, `agent.sh`, `_sessions/session.jsonl` with a
  freshly authored line 1, and `agent: true` in its `index.md`.
- Keep subagent prompts narrow: one role, one deliverable convention, "reply
  idle when nothing pending" — that is what makes scheduled wakes cheap.
- Your commands run inside the server's pod and share its memory limit. A child
  agent's work counts against it too — don't spawn a fleet doing heavy jobs at once.
