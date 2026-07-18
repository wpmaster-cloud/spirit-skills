# AGENTS.md — spirit-skills

Catalog of agent **skills** served by spirit's `resources-server`. Each top-level directory is one skill (e.g. `git-and-github/`, `media-processing/`, `memory/`, `mcp/`, `data-analysis/`). Content only — no build step.

This is a **git submodule** (`wpmaster-cloud/spirit-skills`) mounted at `spirit/resources-server/skills`. The on-server builder checks out the gitlink SHA recorded in the parent `spirit` repo — so push changes here first, then bump the gitlink in `spirit`, or a build ships the old catalog.
