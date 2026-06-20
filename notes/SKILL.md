---
name: notes
requires: sqlite3, jq
description: >
  Obsidian-style markdown memory: a folder of linked `.md` notes ([[wikilinks]] +
  YAML frontmatter + Observations/Relations) that IS the source of truth, with a
  derived SQLite index for fast full-text and optional semantic recall. Use when
  the agent should build a durable, human-readable knowledge base / "second brain"
  it grows and navigates across sessions — notes, facts, decisions, research,
  project knowledge — and you want memory that lives in git-committable plain
  files, not a database server. The zero-infra, file-based counterpart to the
  `memory` (Postgres + pgvector) skill; pick this for most agents, pick `memory`
  for high-volume semantic recall or a shared fleet store.
---

# Notes — a markdown knowledge graph the agent owns

`compact_session` shrinks the current transcript; this skill is **durable,
inspectable** memory that survives restarts and pod replacements. It is a
**vault of plain `.md` files** — one atomic note each, linked by `[[wikilinks]]`,
with a small `MEMORY.md` index loaded into context each session. A derived
**SQLite index** (`.index.db`) makes recall fast; the markdown is always the
source of truth and the index rebuilds from it (`notes.sh reindex`).

Why this shape (it's what the popular tools converged on — Basic Memory, the
A-Mem / Zettelkasten paper, Cline's "memory bank", the Obsidian-MCP servers):

- **Files = truth, DB = derived.** You and the human can read, grep, and edit the
  notes directly; open the folder in Obsidian if you like. The index is a cache.
- **Wikilinks = the graph.** Relations between notes are explicit and navigable,
  no embeddings required for structure.
- **Persistence is git.** Commit/push the vault — durable across the ephemeral
  pod, with human-readable diffs. (`sqlite3` writes in place, so unlike Postgres
  it is unaffected by the Landlock write-jail.)

## Note format (adopted from Basic Memory)

One file per note. Frontmatter for metadata, two structured sections for content
and graph edges:

```markdown
---
title: Deploy secrets flow
type: fact            # note | fact | profile | episode | task | summary
permalink: deploy-secrets-flow
tags: [deploy, ops]
importance: 0.8       # 0..1, steers what reflect/forget keep
---

## Observations
- [fact] agent-main keeps LLM_API_KEY/ADMIN_TOKEN in the cluster secret #secrets
- [gotcha] passing LLM_API_KEY on deploy without ADMIN_TOKEN drops the token

## Relations
- depends_on [[Admin UI Profile]]
- contradicts [[Old Secrets Note]]
```

- **Observations** — `- [category] fact text #tag`. Atomic, one claim per line.
- **Relations** — `- relation_type [[Target Note]]`. A bare `[[Target]]` indexes
  as `links_to`. Targets that don't exist yet are fine — they mark a note worth
  writing later (same idea as `MEMORY.md`'s forward links).

## Setup

```bash
export NOTES_DIR=/work/notes        # the vault (default: ./notes). Keep it under
                                    # /work so it commits + survives with the agent.
# Optional semantic recall — reuses the agent's own LLM creds, same as `memory`:
export BASE_URL="$BASE_URL" LLM_API_KEY="$LLM_API_KEY"
export EMBED_MODEL=text-embedding-3-small EMBED_DIM=1536   # or MEMORY_EMBEDDER=<cmd>

bash scripts/notes.sh init
```

Embeddings are **optional**. With none configured, recall is full-text (SQLite
FTS5, `ripgrep` fallback) — already strong for an agent's scale. Configure them
and recall becomes **hybrid** (full-text + vector, fused by reciprocal rank, like
the `memory` skill). The embeddings endpoint caveat applies: `$BASE_URL/embeddings`
exists on OpenAI, **not** on `sk-ant-` keys — set `MEMORY_EMBEDDER` there.

## Daily use

```bash
# write / update a note (body on --body or stdin; --link adds a relation)
notes.sh write "Deploy secrets flow" --type fact --tags deploy,ops --importance 0.8 \
  --body $'## Observations\n- [fact] secret holds LLM_API_KEY + ADMIN_TOKEN'
notes.sh write "Admin UI Profile" --link "documented_by:Deploy secrets flow" < draft.md

# recall (hybrid if embeddings on; reinforces what it returns)
notes.sh recall "how are deploy secrets handled?"
notes.sh recall "write-jail postgres" -k 5

# graph
notes.sh link "Deploy secrets flow" depends_on "Admin UI Profile"
notes.sh backlinks "Admin UI Profile"      # what points here

# episodic log + housekeeping
notes.sh daily "deployed agent-main with sqlite3 in the image"
notes.sh recent 7         # notes touched in the last 7 days
notes.sh audit            # metrics for defrag: bloated / orphan / stale / broken links
notes.sh reindex          # rebuild .index.db from the markdown (truth)
notes.sh stats
```

## Brilliant management — the part that matters

A vault that only grows becomes an unsearchable junk drawer. Borrow the two
maintenance passes the leading tools run on a schedule (pair with the **cron**
skill):

- **Reflect** (sleep-time consolidation, 1–2×/day or after a compaction).
  `notes.sh reflect` gathers recent `daily/` + `episode` notes and distills
  **durable** facts, writing a `type: summary` note and updating `MEMORY.md`.
  Goal is *distillation, not duplication* — `MEMORY.md` is curated wisdom, a
  one-line pointer per note, never a copy of the daily log. After writing a
  durable note, consider linking it to related notes (`notes.sh link …`) so the
  graph compounds — and, A-Mem style, refine a neighbour's note if the new one
  sharpens or contradicts it.
- **Defrag** (hygiene, weekly, or when `MEMORY.md` > ~500 lines). Run
  `notes.sh audit`, then with judgment: **split** bloated notes (>~300 lines /
  many topics) into atomic ones, **merge** duplicates, **prune** stale entries,
  fix **broken links**. Rule: **archive, never delete** — move retired notes to
  `archive/` and keep the raw `daily/YYYY-MM-DD.md` as an audit trail. Tag
  uncertain items `(review needed)` rather than dropping them.

## The agent loop

1. **Before acting**, `recall` the task topic; treat top hits as context.
2. **After acting**, `write` what's worth keeping — decisions/preferences as
   `fact`/`profile`, what happened as a `daily` line or `episode`, and `link`
   it into the graph.
3. **Periodically** (cron) `reflect`, then `defrag`, so raw events become compact
   linked knowledge. **Commit + push the vault** so it survives the pod.

## Notes & guardrails

- The vault may hold sensitive context — don't write secrets (keys, tokens) into
  notes, and don't commit a vault to a public repo without checking.
- `reindex` is safe and idempotent; run it after editing notes by hand or pulling
  a vault on a fresh pod (the `.index.db` is derived and git-ignorable).
- One agent owns its vault. A shared fleet vault works (commit/pull), but for
  concurrent multi-writer recall at scale prefer the `memory` (pgvector) skill.
- Inspiration & deeper reading: Basic Memory (format + reflect/defrag skills),
  A-Mem (Zettelkasten note construction → link → evolve), Cline Memory Bank
  (fixed-file project memory). This skill is a native bash take on those ideas.
