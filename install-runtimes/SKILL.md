---
name: install-runtimes
requires: curl, jq, tar
description: >
  Install language runtimes (Go, Node.js, Python) and databases (PostgreSQL +
  pgvector, Redis, MongoDB) as portable binaries — the right build for the
  machine's CPU and libc, no root and no system package manager needed. Use
  whenever a task needs a runtime or database that isn't installed
  (`command -v` says missing), when `pip`/`npm`/`go` aren't found, when setting
  up a tool the agent will run itself, or when you need a vector/SQL store for
  the memory skill. Covers arch (amd64/arm64) and libc (musl on Alpine vs
  glibc) selection, exact download sources, and how to run each.
---

# Install runtimes & databases (no root)

> **Already baked into the deployed container image:** `python3`, `pip`, `node`, `npm`,
> `sqlite3`, `ffmpeg`, `imagemagick`, `git`, `curl`, `jq`, `yq`, `rg` (ripgrep), `file`,
> GNU `sed`/`grep`/`gawk`/`find`/`diff`, `patch`, `xz`, `zstd`, `openssl`, `dig` (bind-tools),
> `jo`, `sponge` (moreutils), `make`, `tree`, `psql` (postgresql-client), `ssh`/`scp`, `rsync`,
> `unzip`, `bc`, GNU `coreutils`. Run `command -v <tool>` to confirm before installing —
> a **slim build** may omit `node`, `ffmpeg`/`imagemagick`, or `python` (image built with
> `WITH_NODE`/`WITH_MEDIA`/`WITH_PYTHON=0`), so trust `command -v`, not this list.
> (So `get.sh node` below is only for dev/glibc boxes — a full deployed agent already has it.)

An ephemeral or non-root agent usually can't `apk add` / `apt install`. The
reliable path is **portable binaries**: download the build that matches the
machine, unpack into a writable prefix, put it on `PATH`. The bundled
`scripts/get.sh` does this for the static-friendly tools; the databases that
have no clean no-root binary are documented with the honest options.

## First: know the machine

Two axes decide every download:

```bash
uname -m                       # x86_64 / amd64  -> amd64       | aarch64 / arm64 -> arm64
ls /lib/ld-musl-* 2>/dev/null  # if this exists you're on musl (Alpine); else glibc
```

**musl vs glibc is the #1 cause of "exec format error" / "not found" on a
binary that downloaded fine.** Alpine (this project's container) is musl;
Debian is glibc. Most vendor tarballs are glibc; on a musl machine you
must pick a musl build or it won't run.

## Language runtimes — use `scripts/get.sh`

```bash
bash scripts/get.sh detect          # show arch / libc / prefix + the PATH line
bash scripts/get.sh go              # latest Go        (static; runs on musl & glibc)
bash scripts/get.sh node            # latest Node LTS  (musl build picked on Alpine)
bash scripts/get.sh uv              # uv: a static Python manager (musl + glibc)
bash scripts/get.sh python 3.12     # CPython via uv
bash scripts/get.sh pgvector        # build the pgvector extension (needs Postgres + toolchain; see Databases)
bash scripts/get.sh all             # go + node + uv
```

Default prefix is `~/.local` (override with `RUNTIME_PREFIX=/work/tools`). After
installing, add it to PATH for the session:

```bash
export PATH="$HOME/.local/bin:$HOME/.local/go/bin:$PATH"
```

Where each comes from, and the musl story:

| Tool | Source | amd64 | arm64 | musl? |
|------|--------|:----:|:----:|-------|
| Go | go.dev/dl (`.linux-<arch>.tar.gz`) | ✅ | ✅ | static — runs anywhere |
| Node.js | nodejs.org/dist; Alpine → unofficial-builds.nodejs.org (`-musl`) | ✅ | ✅ | musl x64 ✅, **musl arm64 often absent** |
| Python | `uv python install` (astral-sh/uv) | ✅ | ✅ | ✅ (uv ships musl) |
| pgvector | source build vs `pg_config` (see Databases) | ✅ | ✅ | needs a toolchain, not a binary |

If Node musl-arm64 is missing on Alpine, install `gcompat` (needs root) and use
the glibc build, or run Node from a glibc base image instead.

## Using them

```bash
go version                                  # Go
node -v && npm -v                           # Node
uv run python -V                            # Python (uv-managed); uv venv && . .venv/bin/activate; uv pip install ...
psql -c 'CREATE EXTENSION vector;'          # enable pgvector once built (per database)
```

## Databases

Databases rarely ship a clean static no-root binary. **Default to running them
as a separate service** (a sidecar container / k8s pod) and connecting over the
network — that's simpler and survives the agent being ephemeral. Install
locally only when you own the box.

> **Running any DB server from a spirit agent — two write-jail gotchas:**
> (1) **The Landlock write-jail breaks Postgres (and other atomic-write DBs), and you cannot fix it from inside a `run_command`.** The jail (`llsandbox`, on by default) denies cross-directory `rename()`, so `initdb` and server startup die with `Cross-device link (os error 18)` / `EXDEV` — *even with every data/temp dir under `/work`*. The jail is fixed when the agent process starts, so **you can't lift it mid-run.** If you hit this, **stop and tell the user/operator** — it needs one of: (a) set `SANDBOX_WRITES=0` in the deploy's `ops/.env` (pod-wide) **and redeploy**, or (b) point you at an **external Postgres** to connect to instead of running one in-pod. Option (b) sidesteps the jail entirely and is the preferred fix for an ephemeral agent — don't keep retrying the local server, surface the choice. (2) Never background a long-lived server inside one `run_command` (`./server &`) — `agent.sh` waits for the whole process group, so the never-exiting server hangs the turn until `COMMAND_TIMEOUT_SEC`. Detach it: `setsid ./server </dev/null >server.log 2>&1 &`, then poll its port.

**PostgreSQL** (no root, portable): use the prebuilt tarballs Zonky publishes
for test frameworks — real `postgres`/`initdb` per platform, including Alpine
(musl):

```bash
# arch token: amd64 | arm64v8 ;  add "-alpine" on musl. Pick a version from the listing.
arch=amd64; [ "$(uname -m)" = aarch64 ] && arch=arm64v8
flavor=""; ls /lib/ld-musl-* >/dev/null 2>&1 && flavor="-alpine"
base="https://repo1.maven.org/maven2/io/zonky/test/postgres/embedded-postgres-binaries-linux-${arch}${flavor}"
ver="$(curl -fsSL "$base/maven-metadata.xml" | grep -oE '<release>[^<]+' | sed 's/<release>//')"
curl -fsSL "$base/$ver/embedded-postgres-binaries-linux-${arch}${flavor}-${ver}.jar" -o /tmp/pg.jar
mkdir -p pg && (cd pg && unzip -oq /tmp/pg.jar && tar xf postgres-linux-*.txz)   # -> pg/bin/{initdb,postgres,psql,...}
# ⚠ Inside a sandboxed agent, initdb/start fail with EXDEV under the write-jail
# (see gotcha above) — needs SANDBOX_WRITES=0 (operator-set + restart) or an
# external Postgres. On your own box (no jail) this just works.
./pg/bin/initdb -D pgdata -U postgres -A trust
./pg/bin/pg_ctl -D pgdata -l pg.log -o "-p 5432" start
./pg/bin/psql -p 5432 -U postgres -c "SELECT version();"
```
With root instead: `apk add postgresql postgresql-contrib` (Alpine) or the PGDG apt repo.

**pgvector** (the vector store for the **memory skill** and any RAG/semantic
search) is a Postgres *extension*, not a standalone server — it lives inside a
Postgres database, which is the whole point: vectors sit next to your relational
rows, one ACID write, JOINs and SQL `WHERE` filters over both. Three ways in,
cleanest first:

```bash
# 1. Service image — prebuilt Postgres + extension, nothing to compile. Default
#    for an ephemeral agent; survives pod replacement as an external service.
podman run -d --name pg -p 5432:5432 -e POSTGRES_PASSWORD=postgres pgvector/pgvector:pg16

# 2. Root on the box: just the extension package for an existing Postgres.
apk add postgresql-pgvector            # Alpine (root); Debian/PGDG: postgresql-16-pgvector

# 3. No package? Build it against whatever Postgres owns pg_config on PATH.
#    Needs git + a C toolchain (make/cc) + that Postgres's dev headers — the
#    runtime image ships none, so 'apk add build-base postgresql-dev' (root)
#    first, or build where you have a compiler. get.sh wraps this:
bash scripts/get.sh pgvector                 # pinned to v0.8.2 (override: get.sh pgvector v0.8.2)
#    …which runs the upstream recipe:
#      git clone --branch v0.8.2 https://github.com/pgvector/pgvector.git
#      cd pgvector && make && make install    # sudo only if pkglibdir isn't yours
#    Release page / tags: https://github.com/pgvector/pgvector/releases/tag/v0.8.2
```

Whichever path, enable it once per database: `psql -c 'CREATE EXTENSION vector;'`.
Then point the memory skill at it via `DATABASE_URL` (see `skills/memory/SKILL.md`).

**Redis** — no official static binary. Root: `apk add redis` then
`redis-server --port 6379 --daemonize yes`. No root: run the `redis:7-alpine`
image as a service, or build from source (`make`, needs a compiler).

**MongoDB** — vendor tarballs are **glibc-only (no musl)**, so they won't run on
Alpine. Glibc host: grab `mongodb-linux-<arch>-*.tgz` from fastdl.mongodb.org
and run `./bin/mongod --dbpath data`. On Alpine/ephemeral: run the
`mongo` image as a service and connect.

## Rules

- Always `command -v <tool>` first — it may already be installed.
- Match arch **and** libc before downloading; on Alpine that means musl.
- Prefer `RUNTIME_PREFIX=/work/...` so installs land on a writable, persistent
  path (and, for a containerized agent, can be committed/pushed if needed).
- For databases, ask "service or local?" first — a sidecar/pod is usually the
  right answer for an ephemeral agent.
