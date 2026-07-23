# AGENTS.md — spirit-skills

Catalog of agent **skills** served by spirit's `resources-server`. Each top-level directory is one skill (e.g. `git-and-github/`, `media-processing/`, `memory/`, `mcp/`, `data-analysis/`). Content only — no build step.

This is the **`spirit-skills` git repo** (`github.com/wpmaster-cloud/spirit-skills`). The `resources-server` serves whatever skills are checked out alongside it: in the fleet layout they live at `resources-server/skills/` (this directory). The on-server builder checks out this repo's current SHA when building the `resources-server` image — so push changes here first, then redeploy `resources-server`, or the catalog ships stale.
