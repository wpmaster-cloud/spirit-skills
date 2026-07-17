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

> **Already baked into the deployed container image:** `python3`, `pip`, `sqlite3`,
> `psql` (postgresql-client), `ffmpeg`/`ffprobe`, `magick`/`convert` (imagemagick),
> `git`, `curl`, `jq`, `rg` (ripgrep), `file`, `sed`, `grep`, `find`, `awk`, `tar`,
> `gzip`, `unzip`, `zip`, `xz`, `zstd`, `openssl`, `dig`/`host`/`nslookup`
> (bind-tools), `ssh`/`scp`, `rsync`, `rclone`, `nc`, `bc`, `tree`, `coreutils`.
>
> **Notably NOT present:** `node`, `npm`, `go`, `make`, `gawk`, `patch`, `uv`,
> `pipx`, `docker`, `yq`, `jo`, `sponge`, `pandoc`, `duckdb`, `exiftool`. Several of
> those have no working no-root install here (see Node.js below) — check with
> `command -v <tool>` and trust *that*, never this list.
>
> **`pip install <x>` fails out of the box** with `error: externally-managed-environment`
> (PEP 668) — Alpine marks the system Python as managed. Make a venv first, in your
> own folder:
>
> ```bash
> python3 -m venv .venv && . .venv/bin/activate && pip install <pkg>
> ```

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

The deployed agent runs on **arm64 + musl**, the least-served combination there is.
A statically linked, single-file binary published for `aarch64`+musl works fine
downloaded into your own folder; anything that only ships glibc builds does not,
and no amount of retrying changes that.

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

Default prefix is `~/.local` — **override it**: `$HOME` is the server's home,
outside your jail, so an install there is denied. Point it at your own folder:

```bash
export RUNTIME_PREFIX="$PWD/tools"
export PATH="$PWD/tools/bin:$PWD/tools/go/bin:$PATH"
```

Where each comes from, and the musl story:

| Tool | Source | amd64 | arm64 | musl? |
|------|--------|:----:|:----:|-------|
| Go | go.dev/dl (`.linux-<arch>.tar.gz`) | ✅ | ✅ | static — runs anywhere |
| Node.js | nodejs.org/dist; Alpine → unofficial-builds.nodejs.org (`-musl`) | ✅ | ✅ | musl x64 ✅, **musl arm64 absent — see below** |
| Python | `uv python install` (astral-sh/uv) | ✅ | ✅ | ✅ (uv ships musl) |
| pgvector | source build vs `pg_config` (see Databases) | ✅ | ✅ | needs a toolchain, not a binary |

**Node.js on the deployed agent: don't.** The image is arm64 + musl, and there is
no reliable jailed install for that pair — official tarballs are glibc-linked, and
unofficial-builds has no musl-arm64 Node. The usual escapes are all closed to you:
`gcompat` needs root, and so does a different base image. `get.sh node` is for
dev/glibc boxes only. If a task genuinely needs Node, the honest answer is **ask
the operator to bake it into `ops/Dockerfile`** — say so and move on rather than
burning turns on installs that cannot work.

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
network — that's simpler, and it sidesteps the jail below entirely. Install
locally only when you own the box.

> **Running any DB server from a spirit agent — two gotchas:**
> (1) **The Landlock jail breaks Postgres (and other atomic-write DBs), and it is not something you can switch off.** The jail denies cross-directory `rename()`, so `initdb` and server startup die with `Cross-device link (os error 18)` / `EXDEV` — *even with every data/temp dir inside your own folder*. It is applied when your process starts, so you cannot lift it mid-run; and it is **not configurable from the app** either — the server hardcodes `FOLDER_LOCK=1` on every run it triggers, so there is no env var to ask an operator to flip. Don't send anyone to edit `ops/.env`: it would change nothing. The real fix is to **connect to an external Postgres** instead of running one in-pod. If a task truly requires an in-pod server, that is an image/deploy change (a sidecar), so surface it and stop retrying the local server.
> (2) Never background a long-lived server inside one `run_command` (`./server &`) — `agent.sh` waits for the whole process group, so the never-exiting server hangs the turn until `COMMAND_TIMEOUT_SEC`. Detach it: `setsid ./server </dev/null >server.log 2>&1 &`, then poll its port.
>
> Also check the pod NetworkPolicy before planning around an external DB: egress is
> **53/80/443 only**, so a remote Postgres on 5432 is unreachable until an operator
> opens the port (see the **net-diag** skill).

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
# ⚠ Inside a spirit agent, initdb/start fail with EXDEV under the Landlock jail
# (see gotcha above) — there is no switch for it; use an external Postgres.
# On your own box (no jail) this just works.
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
# 1. Service image — prebuilt Postgres + extension, nothing to compile. The default:
#    it needs no toolchain and sidesteps the Landlock jail entirely. Needs a box
#    with a container runtime — there is none in the agent image.
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
and run `./bin/mongod --dbpath data`. On Alpine: run the `mongo` image as a
service and connect.

## Rules

- Always `command -v <tool>` first — it may already be installed.
- Match arch **and** libc before downloading; here that means **arm64 + musl**. If
  the project ships no musl build, stop: say it needs baking into the image.
- Set `RUNTIME_PREFIX` to a path **inside your own folder** (`$PWD/tools`). The
  default `~/.local` is the server's home, outside the jail — writes there fail.
  Your folder is on a PVC, so an install there persists; you do not need to commit
  it to keep it.
- For databases, ask "service or local?" first — external is nearly always the
  answer, because the Landlock jail makes an in-pod DB server a dead end.
