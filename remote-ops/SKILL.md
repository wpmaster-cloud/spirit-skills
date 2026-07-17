---
name: remote-ops
requires: ssh, rsync
description: >
  Operate remote hosts over SSH from the agent — run commands, copy and sync files,
  and tunnel ports — using the baked openssh-client + rsync. Use whenever the user
  wants the agent to ssh into a server, run a command on another machine, deploy or
  pull files to/from a remote host, rsync or scp a directory, copy a file over the
  network, set up an SSH tunnel / port-forward, or drive a fleet of boxes over ssh.
  Handles the parts that bite an autonomous (non-interactive) agent: BatchMode so a
  missing key fails fast instead of hanging forever on a password prompt, a sane
  known-hosts trust policy, key resolution, and a dry-run-by-default rsync so you
  see what would change before it changes. Trigger phrases:
  "ssh into", "run on the server", "on the remote host", "deploy to", "rsync",
  "scp", "copy to the server", "pull logs from", "port-forward", "ssh tunnel",
  "remote command", "connect to <host>".
---

# remote-ops — SSH/rsync for a non-interactive agent

Plain `ssh`/`rsync` from the agent's `run_command`. The whole point of this skill
is the **non-interactive hardening**: an agent has no TTY, so the default `ssh`
behaviours (prompt for a password, prompt to trust an unknown host key) turn into
a silent hang until `COMMAND_TIMEOUT_SEC` kills the turn. The bundled scripts set
`BatchMode=yes` (no password prompt — fail fast), a explicit known-hosts file and
trust policy, connect timeouts, and keepalives.

```
skills/remote-ops/
├── SKILL.md
├── config.env.example     # template for host + key defaults
└── scripts/
    ├── _common.sh         # SSH option assembly + target resolution (sourced)
    ├── ssh_run.sh         # run a command (or a piped script) on a remote host
    └── sync.sh            # rsync push/pull over the same transport (dry-run first)
```

All paths are relative to **your own folder** (the `run_command` CWD).

> **Before you start: port 22 is blocked by default.** The pod's NetworkPolicy
> (`ops/spirit.yaml`) allows egress on **53, 80 and 443 only**, so a plain `ssh` to
> port 22 dies at the cluster edge — every host looks unreachable and no flag in
> this skill can fix it. Confirm with the **net-diag** skill (`port.sh <host> 22`)
> before debugging keys. Opening 22, or reaching a host that already listens on
> 443, is an operator change to that manifest — surface it rather than retrying.

## 1. One-time setup

**a. A key.** Key-based auth only — `BatchMode` disables password prompts on
purpose. The key must live **in your own folder**: reads and writes are jailed
there, and `$HOME` points at the *server's* home — outside your jail — so `~/.ssh`
is not yours and may simply be denied. Keep the key on a path you own and pass it
explicitly with `-i` (the scripts do this for you from `SSH_KEY`):

```bash
mkdir -p .ssh && chmod 700 .ssh
# drop the key as ./.ssh/id_remote and lock it down — ssh refuses loose perms:
chmod 600 .ssh/id_remote
export SSH_KEY="$PWD/.ssh/id_remote"
```

Commit nothing secret: the GitHub backup's `.gitignore` already excludes `*.key`,
but a key named `id_remote` is **not** covered — keep keys out of git yourself.

**b. Defaults (so you don't repeat `user@host -i key` every call).** Either env
vars (inherited by `run_command`, never printed) or a `config.env` the scripts
auto-source:

```bash
cp skills/remote-ops/config.env.example remote-ops/config.env
# edit remote-ops/config.env: SSH_HOST, SSH_USER, SSH_KEY, SSH_PORT
```

Env wins over the file. Key vars: `SSH_HOST`, `SSH_USER`, `SSH_PORT` (22),
`SSH_KEY`, `SSH_KNOWN_HOSTS` (`.ssh/known_hosts`, under your own folder because
`~` is not writable by you), `SSH_STRICT`
(`accept-new` = trust-on-first-use, the default; `yes` = strict; `no` = insecure,
never in prod), `SSH_CONNECT_TIMEOUT` (15s).

## 2. Run a command on a remote host

```bash
# uses SSH_HOST/SSH_USER from config/env:
bash skills/remote-ops/scripts/ssh_run.sh -- "uptime; df -h /"

# explicit target overrides the defaults:
bash skills/remote-ops/scripts/ssh_run.sh ubuntu@10.0.0.5 -- "systemctl status nginx"

# pipe a whole script to the remote bash (heredoc, multi-line, etc.):
cat deploy.sh | bash skills/remote-ops/scripts/ssh_run.sh --stdin
```

The remote command's stdout/stderr and exit code propagate back, so you can chain
on success/failure as usual.

## 3. Copy / sync files (rsync over the same SSH)

`sync.sh` does a **dry run by default** — it prints what *would* transfer and
changes nothing until you add `--go`. This is deliberate: an agent firing an
`rsync --delete` at the wrong path is how you lose data.

```bash
# preview, then apply, a push:
bash skills/remote-ops/scripts/sync.sh push ./dist/ /var/www/app/        # dry-run
bash skills/remote-ops/scripts/sync.sh push ./dist/ /var/www/app/ --go   # apply

# pull logs down:
bash skills/remote-ops/scripts/sync.sh pull /var/log/app/ ./logs/ --go

# mirror (delete extras at the destination) — pass it through after --:
bash skills/remote-ops/scripts/sync.sh push ./site/ /srv/site/ --go -- --delete
```

Trailing slashes follow rsync's rules: `src/` copies the *contents* of `src` into
`dst`; `src` (no slash) copies the directory itself. The scripts default to
`-az --partial` with human-readable stats.

## 4. Port-forward / tunnel

A tunnel is a long-lived process, so **never** run it foreground in a
`run_command` — `agent.sh` waits for the whole process group and the turn hangs
until timeout. Launch it detached, use it, then kill it:

```bash
# forward a remote DB to localhost:5433 in the background
setsid ssh -f -N -o BatchMode=yes -i "$SSH_KEY" \
  -L 5433:localhost:5432 ubuntu@$SSH_HOST </dev/null >tunnel.log 2>&1
# ... use localhost:5433 ...
pkill -f '5433:localhost:5432'     # tear it down when done
```

`-f -N` (go to background, no remote command) is the canonical non-interactive
tunnel. Note it needs the SSH port itself to be reachable, so the NetworkPolicy
caveat above applies to tunnels first of all.

## Gotchas (read before debugging a hang)

- **Every host unreachable / connect times out** ⇒ suspect the pod NetworkPolicy
  (egress 53/80/443 only) before you suspect the host or the key. `port.sh <host>
  22` from **net-diag** settles it in one call.
- **Hang on connect** ⇒ almost always a host-key or auth prompt the agent can't
  answer. The scripts set `BatchMode=yes` + `ConnectTimeout`, so they error out
  instead — if you call `ssh` directly, add those yourself.
- **"Host key verification failed"** ⇒ first contact under `SSH_STRICT=yes`. Use
  `accept-new` (default) for TOFU, or pre-seed `known_hosts` with
  `ssh-keyscan -p "$SSH_PORT" "$SSH_HOST" >> "$SSH_KNOWN_HOSTS"`.
- **"Permissions 0644 for key are too open"** ⇒ `chmod 600` the key.
- **Permission denied reading the key / `known_hosts`** ⇒ the path is outside your
  folder. `~` is the server's home, not yours: keep both under your own folder and
  point `SSH_KEY`/`SSH_KNOWN_HOSTS` at them.
- **Egress** ⇒ there is no VPN or proxy; SSH exits the cluster node's own public
  IP, which is stable. That is the address to give a remote box that allowlists
  source IPs — read it with **net-diag**'s `egress.sh`.
- **Don't bake host trust into a public repo** — `known_hosts` is fine to commit,
  private keys are not.
