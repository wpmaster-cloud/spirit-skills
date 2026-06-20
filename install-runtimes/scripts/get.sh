#!/usr/bin/env bash
# get.sh — install language runtimes and a few servers as portable binaries,
# no root and no system package manager. Picks the right build for the machine's
# CPU arch and libc (musl on Alpine, glibc elsewhere), resolves the latest
# version, and unpacks into a prefix on your PATH.
#
# Usage:
#   get.sh detect                 # print arch / libc / prefix and exit
#   get.sh go [version]           # Go toolchain          -> $PREFIX/go/bin
#   get.sh node [version]         # Node.js (LTS default) -> $PREFIX/bin
#   get.sh uv                     # uv (Python manager)   -> $PREFIX/bin
#   get.sh python [version]       # uv + that CPython     (via: uv python install)
#   get.sh pgvector [version]     # build pgvector ext    (against pg_config on PATH; default v0.8.2)
#   get.sh all                    # go + node + uv
#
# Prefix defaults to $RUNTIME_PREFIX, else ~/.local. After installing, add it
# to PATH (the script prints the exact line).
set -euo pipefail

PREFIX="${RUNTIME_PREFIX:-$HOME/.local}"
mkdir -p "$PREFIX/bin"

# ---- detect arch + libc, expressed in each ecosystem's naming -----------------
case "$(uname -m)" in
  x86_64|amd64)  GOARCH=amd64; NODEARCH=x64;   TRIPLE_CPU=x86_64 ;;
  aarch64|arm64) GOARCH=arm64; NODEARCH=arm64; TRIPLE_CPU=aarch64 ;;
  *) echo "unsupported CPU: $(uname -m)" >&2; exit 2 ;;
esac
if ls /lib/ld-musl-* >/dev/null 2>&1 || (ldd --version 2>&1 | grep -qi musl); then
  LIBC=musl
else
  LIBC=gnu
fi

say()  { printf '\033[1m==>\033[0m %s\n' "$*" >&2; }
die()  { printf 'get.sh: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
# Fetch a URL to stdout, failing loudly (with the URL) on any HTTP error.
fetch() { curl -fsSL "$1" || die "download failed: $1 (try the other libc, or check the project's releases page)"; }

detect() {
  printf 'arch=%s  libc=%s  prefix=%s\n' "$TRIPLE_CPU" "$LIBC" "$PREFIX"
  # shellcheck disable=SC2016  # $PATH is intentionally literal for the user to paste
  printf 'PATH line:  export PATH="%s/bin:%s/go/bin:$PATH"\n' "$PREFIX" "$PREFIX"
}

install_go() {     # static binaries; the same build runs on glibc and musl
  local ver="${1:-}"
  [ -n "$ver" ] || ver="$(fetch 'https://go.dev/dl/?mode=json' | jq -r '.[0].version')"
  [ -n "$ver" ] || die "could not resolve latest Go version"
  say "Go $ver ($GOARCH) -> $PREFIX/go"
  rm -rf "$PREFIX/go"
  fetch "https://go.dev/dl/${ver}.linux-${GOARCH}.tar.gz" | tar -C "$PREFIX" -xz
  "$PREFIX/go/bin/go" version
}

install_node() {
  local ver="${1:-}" base file
  [ -n "$ver" ] || ver="$(fetch https://nodejs.org/dist/index.json | jq -r '[.[]|select(.lts!=false)][0].version')"
  [ -n "$ver" ] || die "could not resolve latest Node LTS"
  if [ "$LIBC" = musl ]; then
    # Official Node is glibc-only; musl builds come from the unofficial builds site.
    base="https://unofficial-builds.nodejs.org/download/release"
    file="node-${ver}-linux-${NODEARCH}-musl.tar.xz"
    say "Node $ver ($NODEARCH, musl) -> $PREFIX  [unofficial-builds; arm64-musl may be absent]"
  else
    base="https://nodejs.org/dist"
    file="node-${ver}-linux-${NODEARCH}.tar.xz"
    say "Node $ver ($NODEARCH, glibc) -> $PREFIX"
  fi
  fetch "${base}/${ver}/${file}" | tar -C "$PREFIX" --strip-components=1 -xJ
  "$PREFIX/bin/node" --version
}

install_uv() {     # single static binary that also manages Python versions
  local file="uv-${TRIPLE_CPU}-unknown-linux-${LIBC}.tar.gz"
  say "uv ($TRIPLE_CPU, $LIBC) -> $PREFIX/bin"
  fetch "https://github.com/astral-sh/uv/releases/latest/download/${file}" \
    | tar -C "$PREFIX/bin" --strip-components=1 -xz
  "$PREFIX/bin/uv" --version
}

install_python() { # delegate to uv, the cleanest no-root CPython path
  local ver="${1:-3.12}"
  have uv || install_uv
  say "CPython $ver via uv"
  "$PREFIX/bin/uv" python install "$ver"
  say "use it with:  uv run python ...   |   uv venv && . .venv/bin/activate"
}

install_pgvector() { # build the pgvector extension against the Postgres that owns pg_config on PATH
  # Not a portable binary: pgvector is a C extension compiled against ONE Postgres
  # install. Needs git + a C toolchain (make, cc) + that Postgres's dev headers
  # (pg_config). The runtime image ships none of those, so the clean default is to
  # run the prebuilt `pgvector/pgvector:pg16` image as a service; build only when
  # you own a Postgres and just need the extension dropped into it.
  local ver="${1:-${PGVECTOR_VERSION:-v0.8.2}}" src
  have git       || die "pgvector needs git to fetch the source"
  have make      || die "pgvector needs a C toolchain ('make' not found): root 'apk add build-base', or use the pgvector/pgvector image as a service"
  have pg_config || die "pgvector builds against an installed Postgres ('pg_config' not on PATH): install its dev headers ('apk add postgresql-dev' as root) or put your portable pg's bin/ on PATH"
  src="$(mktemp -d)"
  say "pgvector $ver -> building against $(pg_config --version) [pkglibdir: $(pg_config --pkglibdir)]"
  git clone --depth 1 --branch "$ver" https://github.com/pgvector/pgvector.git "$src" \
    || die "clone failed — confirm the tag exists: https://github.com/pgvector/pgvector/releases"
  make -C "$src"
  # `make install` writes into Postgres's lib/share dirs: skip sudo if they're ours.
  if [ -w "$(pg_config --pkglibdir)" ]; then
    make -C "$src" install
  else
    say "pkglibdir not writable; installing with sudo (needs root)"
    sudo make -C "$src" install
  fi
  rm -rf "$src"
  say "installed. enable it per-database:  psql -c 'CREATE EXTENSION vector;'"
}

case "${1:-}" in
  detect)  detect ;;
  go)      install_go "${2:-}" ;;
  node)    install_node "${2:-}" ;;
  uv)       install_uv ;;
  python)   install_python "${2:-}" ;;
  pgvector) install_pgvector "${2:-}" ;;
  all)      install_go; install_node; install_uv ;;
  ""|-h|--help) sed -n '2,20p' "$0" ;;
  *) die "unknown target: $1 (try: detect go node uv python pgvector all)" ;;
esac

[ "${1:-}" = detect ] || { echo; detect; }
