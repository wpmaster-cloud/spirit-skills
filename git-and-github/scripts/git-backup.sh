#!/usr/bin/env bash
# git-backup.sh — bind an agent's workspace to its private GitHub backup repo.
# GitHub is the agent's durable store: backup, recovery, and persistence of files.
#
# Run with NO arguments, from the workspace:
#
#   ./git-backup.sh
#
#   - .git already present  -> do NOTHING (already bound; the agent persists its
#                              own changes with the everyday git add/commit/push).
#   - .git absent, backup repo spirit-agent-<name> EXISTS on GitHub
#                           -> RECOVER: init, fetch, hard-reset the workspace to
#                              the remote, set upstream (a fresh/replaced pod gets
#                              its backed-up files back).
#   - .git absent, NO such repo
#                           -> CREATE the private repo, init, commit, push, set
#                              upstream (first backup of this workspace).
#
# Requires GITHUB_TOKEN (and optionally GIT_USER_NAME / GIT_USER_EMAIL) in the
# environment. The repo is always spirit-agent-<agent_name>, where <agent_name>
# is resolved exactly as agent.sh resolves it, so the repo and the agent's own
# identity agree. Everything is BEST-EFFORT: a backup problem must never fail the
# agent, so no failure path propagates a non-zero exit.
set -uo pipefail

# colors only on a terminal
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then C_TOOL=$'\033[33m'; C_RESET=$'\033[0m'; else C_TOOL=''; C_RESET=''; fi

warn() { printf '%sgit-backup:%s %s\n' "$C_TOOL" "$C_RESET" "$1" >&2; }

# Same normalization as agent.sh: lowercase a-z0-9 + dashes, never empty. Env
# AGENT_NAME wins (agent.yaml sets it); else the folder name.
agent_name() {
  local dir="$1" n
  n="$(printf '%s' "${AGENT_NAME:-$(basename "$dir")}" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-')"
  n="${n#-}"; n="${n%-}"; printf '%s' "${n:-agent}"
}

# GitHub REST over curl. Bounded bodies only (a short repo name) → argv is safe.
gh_api() {  # METHOD PATH [json-body]; prints body, nonzero on HTTP >=400
  curl -fsS -X "$1" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com$2" ${3:+--data "$3"}
}
gh_code() { # METHOD PATH; prints HTTP status code only (existence probe)
  curl -s -o /dev/null -w '%{http_code}' -X "$1" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com$2"
}

# Backed up = the agent's DATA. Excluded: secrets, the runtime code (agent.sh is
# shipped by the image — backing it up would let a restore revert a redeployed
# runtime), and per-run scratch/locks. Tracked on purpose: session*.jsonl (the
# memory), agent.log, skills/, agents/ and work products. Patterns are
# slash-free so they match at any depth (incl. agents/*/). Only written if
# absent, so a hand-tuned one is respected.
write_gitignore() {
  local dir="$1"
  [[ -e "$dir/.gitignore" ]] && return 0
  cat > "$dir/.gitignore" <<'GITIGNORE'
# secrets — never commit these (matches at any depth, incl. agents/*/)
.env
profile.env
*.key

# the agent runtime is CODE shipped by the image, not backed-up DATA — keep it
# out so a restore never reverts a redeployed agent.sh
agent.sh

# offloaded tool-result bodies — large, pod-local, regenerable; the session
# keeps a head/tail pointer to each, so the raw bodies stay out of the backup
tool_outputs/

# locks, per-run scratch, compaction backups (any depth)
*.lock/
.seed.lock
.llm-*.*
.cmd-*.*
.session-compact.*
.session-offload.*
.agent.dec.*
*.jsonl.bak.*
GITIGNORE
}

# bind <dir> to its private spirit-agent-<name> backup repo. Idempotent (.git
# present → skip), token-gated, best-effort. On any failure: warn and drop the
# partial .git so a later run retries clean — never block the agent.
backup() {
  local dir="$1"
  dir="$(cd "$dir" 2>/dev/null && pwd)" || { warn "no such dir: $1"; return 0; }
  [[ -e "$dir/.git" ]] && return 0                          # already bound → nothing
  [[ -n "${GITHUB_TOKEN:-}" ]] || { warn "no GITHUB_TOKEN; skipping backup"; return 0; }
  command -v git  >/dev/null 2>&1 || { warn "git not found; skipping backup";  return 0; }
  command -v curl >/dev/null 2>&1 || { warn "curl not found; skipping backup"; return 0; }

  local name repo
  name="$(agent_name "$dir")"
  repo="spirit-agent-$name"
  (
    set -e
    local owner branch
    owner="$(gh_api GET /user | jq -r '.login // empty')"
    [[ -n "$owner" ]] || { warn "/user failed (bad token?)"; exit 1; }

    git -C "$dir" init -q -b main
    git -C "$dir" config user.name  "${GIT_USER_NAME:-$name}"
    git -C "$dir" config user.email "${GIT_USER_EMAIL:-$name@spirit.local}"
    write_gitignore "$dir"
    git -C "$dir" remote add origin \
      "https://x-access-token:${GITHUB_TOKEN}@github.com/$owner/$repo.git"

    if [[ "$(gh_code GET "/repos/$owner/$repo")" == 200 ]]; then
      # repo EXISTS — recover its files if it has any, else fall through to seed.
      branch="$(gh_api GET "/repos/$owner/$repo" | jq -r '.default_branch // "main"')"
      git -C "$dir" fetch -q origin
      if git -C "$dir" rev-parse -q --verify "origin/$branch" >/dev/null 2>&1; then
        # reset --hard (not checkout): overwrites baked data files that are also
        # in the backup without an "untracked would be overwritten" abort, and
        # leaves untracked-but-unbacked files (agent.sh, profile.env) in place.
        git -C "$dir" reset -q --hard "origin/$branch"
        git -C "$dir" branch -q --set-upstream-to "origin/$branch" 2>/dev/null || true
        printf 'git-backup: recovered %s/%s@%s\n' "$owner" "$repo" "$branch"
        exit 0
      fi
      # repo exists but is EMPTY → fall through to seed it below.
    else
      # NO such repo → create it private (422 = race/already exists = fine).
      gh_api POST /user/repos \
        "$(jq -nc --arg n "$repo" '{name:$n, private:true, auto_init:false}')" >/dev/null \
        || [[ "$(gh_code GET "/repos/$owner/$repo")" == 200 ]]
    fi

    # seed: first backup of this workspace; -u sets upstream.
    git -C "$dir" add -A
    git -C "$dir" commit -q -m "init: spirit agent $name workspace backup"
    git -C "$dir" push -q -u origin HEAD
    printf 'git-backup: created %s/%s\n' "$owner" "$repo"
  ) || { warn "backup skipped; continuing without it"; rm -rf -- "$dir/.git"; }
}

backup "${1:-.}"
