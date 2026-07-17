---
name: git-and-github
description: >
  Version control with git, and GitHub repo/PR/issue work using only git and
  the GitHub REST API over curl — no gh CLI required. Use whenever the task
  involves committing, branching, pushing, cloning, diffing, or history; or
  creating/listing PRs, issues, and repos on GitHub. Use it when work needs
  version history, review, or to be shared off-box.
requires: git, curl
---

# Git & GitHub (no gh CLI)

Plain `git` for version control; the GitHub **REST API over `curl`** for
GitHub-side actions. This needs no `gh` binary — only `git`, `curl`, and a
token in `$GITHUB_TOKEN` (a fine-grained or classic PAT).

## Auth

Set identity once per repo, and authenticate remotes by putting the token in
the URL (never commit it). Identity and token come from the environment —
`GIT_USER_NAME`, `GIT_USER_EMAIL`, and `GITHUB_TOKEN` — from the deployment env
or your own agent `.env`. If they are missing, say so rather than improvising:

```bash
git config user.name  "${GIT_USER_NAME:-agent}"
git config user.email "${GIT_USER_EMAIL:-agent@example.com}"
git remote set-url origin "https://x-access-token:${GITHUB_TOKEN}@github.com/<owner>/<repo>.git"
```

For the REST API, send the token as a bearer header (shown as `$GITHUB_TOKEN`
below). Treat the token as a secret: never echo it, never commit it.

## Everyday git

```bash
git status                                   # always look before committing
git switch -c feature/x                       # work on a branch, not main
git add -A && git commit -m "feat: describe the change"
git push -u origin "$(git branch --show-current)"
git log --oneline -n 10
git diff                                      # unstaged   (--staged for staged)
```

## What git is (and isn't) for here

**Your folder is not ephemeral.** It lives in the vault, which sits on persistent
storage and is synced to backup by the deployment — your files survive a restart
without you doing anything. So git is **not** your survival mechanism, and you do
not need to push to keep your work.

Use git for what it actually gives you: **history, diffs, review, and an off-box
copy under your control.** That makes it right for code, documents that evolve,
and anything you want to roll back or share — and unnecessary for ordinary notes.

A checkpoint at the end of a wake that produced real work:

```bash
git add -A && git commit -m "checkpoint: <what changed> $(date -u +%FT%TZ)" && git push || echo "nothing to push"
```

Read the push output — a push that printed an error is not a backup.

## Workspace backup & recovery (`scripts/git-backup.sh`)

`scripts/git-backup.sh` binds the workspace to its own private GitHub repo named
`spirit-agent-<agent-name>` — the durable store for backup, recovery, and file
persistence. Run it once, with **no arguments**, from the workspace:

```bash
skills/git-and-github/scripts/git-backup.sh     # operates on the current directory
```

What it does depends on the workspace state:

- **`.git` already present** → nothing. The workspace is already bound; persist
  ongoing changes yourself with the everyday `git add/commit/push` above.
- **No `.git`, but `spirit-agent-<name>` exists on GitHub** → *recover*: it inits,
  fetches, hard-resets the workspace to the remote, and sets upstream — a fresh or
  replaced pod gets its backed-up files back.
- **No `.git`, no such repo** → *create*: it makes the private repo, inits, commits,
  pushes, and sets upstream (first backup of this workspace).

Needs `GITHUB_TOKEN` (and optionally `GIT_USER_NAME` / `GIT_USER_EMAIL`). It is
best-effort — a backup problem warns but never fails the run — and it never backs
up secrets, `agent.sh`, `tool_outputs/`, or locks (see the `.gitignore` it writes).

## GitHub via REST (curl)

One helper, then call any endpoint (https://docs.github.com/rest):

```bash
gh_api() {  # gh_api METHOD PATH [json-body]
  curl -fsSL -X "$1" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com$2" \
    ${3:+-d "$3"}
}
```

```bash
# Open a PR (build the body with jq so quoting is safe)
gh_api POST /repos/<owner>/<repo>/pulls \
  "$(jq -nc --arg t "My title" --arg h "feature/x" --arg b "main" --arg body "Summary." \
        '{title:$t, head:$h, base:$b, body:$body}')"

# List open PRs (pull fields out with jq)
gh_api GET '/repos/<owner>/<repo>/pulls?state=open' | jq -r '.[] | "#\(.number) \(.title)"'

# Create an issue
gh_api POST /repos/<owner>/<repo>/issues "$(jq -nc --arg t "Bug: ..." '{title:$t}')"

# Create a repo for the authenticated user
gh_api POST /user/repos "$(jq -nc --arg n "new-repo" '{name:$n, private:true}')"
```

## Guardrails

- Branch for changes; keep `main` clean. Run `git status` before committing.
- Never commit secrets/tokens; never print `$GITHUB_TOKEN`.
- `curl -f` makes HTTP errors fail the command instead of returning error JSON
  silently — keep it so a failed API call is visible.
