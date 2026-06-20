#!/usr/bin/env bash
# vercel.sh — deploy to Vercel (free/Hobby tier) and get a live URL back.
#
# Usage:
#   vercel.sh deploy [path] [--prod] [--public] [-- <extra vercel flags>]
#   vercel.sh env add NAME [target]        # value from $VALUE, else CLI prompts
#   vercel.sh env ls
#   vercel.sh logs <deployment-url>
#   vercel.sh ls
#   vercel.sh whoami                        # fastest token sanity check
#   vercel.sh ensure                        # bootstrap Node + CLI, print versions
#
# deploy: preview by default; --prod for a PUBLIC production deploy (returns the
# public alias); --public disables deployment protection so preview urls are
# viewable too (otherwise anonymous visitors get 401). stdout is ONLY the
# resulting URL; the CLI's progress/setup chatter goes to stderr, so:
#   url="$(vercel.sh deploy ./site --prod)"
#
# Credentials: env wins; otherwise the first existing file of $VERCEL_CONFIG,
# vercel/config.env, skills/vercel/config.env is sourced. VERCEL_TOKEN is
# required (https://vercel.com/account/tokens). Optional: VERCEL_TEAM (slug ->
# --scope), VERCEL_ORG_ID + VERCEL_PROJECT_ID (both or neither). The CLI reads
# VERCEL_TOKEN natively — it is never passed as --token and never echoed.
#
# Node isn't baked into the agent image; it's bootstrapped via the
# install-runtimes skill on first use. Set RUNTIME_PREFIX / VERCEL_NPM_PREFIX to
# a persistent path (e.g. /work/tools) so the toolchain survives cold starts.

set -euo pipefail

command -v curl >/dev/null 2>&1 || { echo "vercel.sh: curl is required" >&2; exit 1; }
command -v jq   >/dev/null 2>&1 || { echo "vercel.sh: jq is required"   >&2; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"
VC_BIN=""   # resolved Vercel CLI invocation, set by ensure_cli

# --- credentials: env wins; else source the first config file that exists -----
load_token() {
  if [ -z "${VERCEL_TOKEN:-}" ]; then
    for _cfg in "${VERCEL_CONFIG:-}" "vercel/config.env" "skills/vercel/config.env" \
                "$HERE/../config.env"; do
      if [ -n "$_cfg" ] && [ -f "$_cfg" ]; then
        # shellcheck disable=SC1090
        . "$_cfg"
        break
      fi
    done
  fi
  [ -n "${VERCEL_TOKEN:-}" ] || {
    echo "vercel.sh: VERCEL_TOKEN is not set — create one at https://vercel.com/account/tokens," >&2
    echo "           then export it or put it in skills/vercel/config.env" >&2
    exit 2
  }
  export VERCEL_TOKEN
  if [ -n "${VERCEL_ORG_ID:-}" ] || [ -n "${VERCEL_PROJECT_ID:-}" ]; then
    if [ -z "${VERCEL_ORG_ID:-}" ] || [ -z "${VERCEL_PROJECT_ID:-}" ]; then
      echo "vercel.sh: set VERCEL_ORG_ID and VERCEL_PROJECT_ID together, or neither" >&2
      exit 2
    fi
    export VERCEL_ORG_ID VERCEL_PROJECT_ID
  fi
}

# Vercel refuses to pick a scope non-interactively when the token can see more
# than one account, and the personal account can't be used as --scope. So
# resolve it once: explicit VERCEL_TEAM wins; a pinned VERCEL_ORG_ID already
# implies the scope; otherwise auto-detect the token's team(s) via the API and
# use the single one (a Hobby/free team is still the free tier). No team at all
# => a pure personal token, where omitting --scope is correct.
API="${VERCEL_API:-https://api.vercel.com}"
VC_SCOPE="" VC_TEAM_ID="" VC_SCOPE_DONE=0
resolve_scope() {
  [ "$VC_SCOPE_DONE" -eq 1 ] && return 0
  VC_SCOPE_DONE=1
  [ -n "${VERCEL_ORG_ID:-}" ] && { VC_TEAM_ID="$VERCEL_ORG_ID"; return 0; }
  local json count
  json="$(curl -fsS "$API/v2/teams" -H "Authorization: Bearer $VERCEL_TOKEN" 2>/dev/null || true)"
  if [ -n "${VERCEL_TEAM:-}" ]; then
    VC_SCOPE="$VERCEL_TEAM"
    VC_TEAM_ID="$(printf '%s' "$json" | jq -r --arg s "$VC_SCOPE" '.teams[]|select(.slug==$s)|.id' 2>/dev/null | head -n1)"
    return 0
  fi
  count="$(printf '%s' "$json" | jq -r '.teams | length' 2>/dev/null || echo 0)"
  if [ "${count:-0}" = "1" ]; then
    VC_SCOPE="$(printf '%s' "$json" | jq -r '.teams[0].slug')"
    VC_TEAM_ID="$(printf '%s' "$json" | jq -r '.teams[0].id')"
  elif [ "${count:-0}" -gt 1 ]; then
    echo "vercel.sh: this token can reach multiple teams — set VERCEL_TEAM to one of:" >&2
    printf '%s' "$json" | jq -r '.teams[].slug' | sed 's/^/  /' >&2
    exit 2
  fi
  # count 0 => pure personal token; leave scope empty (CLI default works).
}

# Query string that scopes a REST call to the resolved team (teamId preferred).
api_scope_q() {
  if   [ -n "${VC_TEAM_ID:-}" ]; then printf '?teamId=%s' "$VC_TEAM_ID"
  elif [ -n "${VC_SCOPE:-}" ];   then printf '?slug=%s'   "$VC_SCOPE"
  fi
}
# Append --scope <resolved> to an args array name, when a scope is known.
add_scope() { # add_scope ARRAYNAME
  resolve_scope
  [ -n "$VC_SCOPE" ] || return 0
  eval "$1+=(--scope \"\$VC_SCOPE\")"
}

# --- bootstrap Node via the install-runtimes skill, if npm is missing ---------
bootstrap_node() {
  command -v npm >/dev/null 2>&1 && return 0
  local prefix="${RUNTIME_PREFIX:-$HOME/.local}" get=""
  for _c in "skills/install-runtimes/scripts/get.sh" \
            "$HERE/../../install-runtimes/scripts/get.sh" \
            "$HOME/skills/install-runtimes/scripts/get.sh"; do
    [ -f "$_c" ] && { get="$_c"; break; }
  done
  if [ -n "$get" ]; then
    echo "vercel.sh: Node/npm missing — bootstrapping via install-runtimes ($get)..." >&2
    RUNTIME_PREFIX="$prefix" bash "$get" node >&2 || true
  else
    echo "vercel.sh: Node/npm missing and install-runtimes get.sh not found." >&2
    echo "           Install Node, or fetch skills (see CLAUDE.md), then retry." >&2
  fi
  export PATH="$prefix/bin:$PATH"
  command -v npm >/dev/null 2>&1 || {
    echo "vercel.sh: still no npm after bootstrap. On musl+arm64 (Alpine on ARM) a" >&2
    echo "           prebuilt Node may be unavailable — see skills/install-runtimes/SKILL.md." >&2
    exit 1
  }
}

# --- resolve the Vercel CLI: existing -> global install -> npx fallback --------
ensure_cli() {
  if command -v vercel >/dev/null 2>&1; then VC_BIN="vercel"; return; fi
  bootstrap_node
  local prefix="${VERCEL_NPM_PREFIX:-${RUNTIME_PREFIX:-$HOME/.local}}"
  mkdir -p "$prefix" 2>/dev/null || true
  echo "vercel.sh: installing the Vercel CLI into $prefix (one-time)..." >&2
  if npm install -g --prefix "$prefix" vercel >&2 2>&1; then
    export PATH="$prefix/bin:$PATH"
  fi
  if command -v vercel >/dev/null 2>&1; then VC_BIN="vercel"; return; fi
  if command -v npx >/dev/null 2>&1; then
    echo "vercel.sh: global install unavailable — falling back to 'npx vercel@latest' (slower)." >&2
    VC_BIN="npx --yes vercel@latest"; return
  fi
  echo "vercel.sh: could not obtain the Vercel CLI (no npm/npx)." >&2
  exit 1
}

# Run the resolved CLI (VC_BIN may be multiple words for the npx fallback).
vc() { $VC_BIN "$@"; }

usage() { sed -n '2,25p' "$0" | cut -c3-; }

# --- dispatch -----------------------------------------------------------------
cmd="${1:-}"; [ $# -gt 0 ] && shift || true

case "$cmd" in
  deploy)
    load_token; ensure_cli
    prod=0 public=0 path="." extra=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --prod)     prod=1; shift ;;
        --public)   public=1; shift ;;
        -h|--help)  echo "usage: vercel.sh deploy [path] [--prod] [--public] [-- <extra vercel flags>]"; exit 0 ;;
        --)         shift; while [ $# -gt 0 ]; do extra+=("$1"); shift; done ;;
        -*)         extra+=("$1"); shift ;;
        *)          path="$1"; shift ;;
      esac
    done
    [ -e "$path" ] || { echo "vercel.sh: path not found: $path" >&2; exit 2; }
    args=(deploy --yes --cwd "$path")
    add_scope args
    [ "$prod" -eq 1 ] && args+=(--prod)
    [ "${#extra[@]}" -gt 0 ] && args+=("${extra[@]}")
    # Capture stdout while the CLI's progress streams live on stderr. On a
    # non-TTY stdout (i.e. whenever an agent runs this) the CLI emits a JSON
    # envelope: {status, deployment:{url,...}, message, next[]}. On a TTY/older
    # CLI it's a bare URL. Parse the JSON, fall back to a bare *.vercel.app URL.
    set +e; out="$(vc "${args[@]}")"; rc=$?; set -e
    url=""
    if printf '%s' "$out" | jq -e 'type=="object"' >/dev/null 2>&1; then
      st="$(printf '%s' "$out" | jq -r '.status // "ok"')"
      if [ "$st" != "ok" ]; then
        printf '%s\n' "$out" | jq -r '.message // .error.message // "deploy failed"' >&2
        echo "vercel.sh: deploy failed (status: $st)" >&2
        exit 1
      fi
      url="$(printf '%s' "$out" | jq -r '.deployment.url // .url // empty')"
    fi
    [ -n "$url" ] || \
      url="$(printf '%s\n' "$out" | grep -Eo 'https://[a-zA-Z0-9._-]+\.vercel\.app[^"[:space:]]*' | tail -n1 || true)"
    if [ -z "$url" ]; then
      [ -n "$out" ] && printf '%s\n' "$out" >&2
      echo "vercel.sh: deploy finished (rc=$rc) but no URL could be parsed from the output above" >&2
      exit 1
    fi
    # --public: disable Vercel Authentication so ALL urls (incl. preview) are
    # publicly viewable. (By default the per-deployment *.vercel.app hostnames
    # return 401 to anonymous visitors; only the production alias is public.)
    if [ "$public" -eq 1 ]; then
      projid="$(jq -r '.projectId // empty' "$path/.vercel/project.json" 2>/dev/null || true)"
      if [ -n "$projid" ] && curl -fsS -X PATCH "$API/v9/projects/$projid$(api_scope_q)" \
           -H "Authorization: Bearer $VERCEL_TOKEN" -H 'Content-Type: application/json' \
           --data '{"ssoProtection":null}' >/dev/null 2>&1; then
        echo "vercel.sh: deployment protection disabled — all URLs are now public." >&2
      else
        echo "vercel.sh: could not disable protection (token may lack project scope); URLs may 401." >&2
      fi
    fi
    # For production, the per-deployment hostname is protected; the public,
    # shareable URL is the production alias — resolve it from the deployment.
    if [ "$prod" -eq 1 ]; then
      did="$(printf '%s' "$out" | jq -r '.deployment.id // empty' 2>/dev/null || true)"
      if [ -n "$did" ]; then
        al="$(curl -fsS "$API/v13/deployments/$did$(api_scope_q)" \
               -H "Authorization: Bearer $VERCEL_TOKEN" 2>/dev/null \
             | jq -r '(.alias // []) | map(select(endswith(".vercel.app"))) | sort_by(length) | .[0] // empty' 2>/dev/null || true)"
        [ -n "$al" ] && url="https://$al"
      fi
    elif [ "$public" -ne 1 ]; then
      echo "vercel.sh: note — this preview URL is protected by Vercel Authentication (anonymous" >&2
      echo "           visitors get 401). Re-run with --prod for a public alias, or --public to" >&2
      echo "           make all URLs public." >&2
    fi
    printf '%s\n' "$url"
    ;;

  env)
    load_token; ensure_cli
    sub="${1:-ls}"; [ $# -gt 0 ] && shift || true
    case "$sub" in
      add)
        name="${1:?usage: vercel.sh env add NAME [target]}"
        target="${2:-production}"
        args=(env add "$name" "$target")
        add_scope args
        if [ -n "${VALUE:-}" ]; then
          printf '%s' "$VALUE" | vc "${args[@]}" --yes
        else
          echo "vercel.sh: no \$VALUE set — the CLI will prompt for the value." >&2
          vc "${args[@]}"
        fi
        ;;
      ls|list|"")
        args=(env ls); add_scope args; vc "${args[@]}" ;;
      *)
        echo "vercel.sh: env subcommand must be 'add' or 'ls'" >&2; exit 2 ;;
    esac
    ;;

  logs)
    load_token; ensure_cli
    target="${1:?usage: vercel.sh logs <deployment-url>}"
    args=(inspect "$target" --logs); add_scope args
    vc "${args[@]}" ;;

  ls|list)
    load_token; ensure_cli
    args=(ls); add_scope args
    vc "${args[@]}" "$@" ;;

  whoami)
    load_token; ensure_cli
    vc whoami ;;

  ensure|setup)
    load_token; ensure_cli
    echo "node: $(node -v 2>/dev/null || echo missing)" >&2
    echo "npm:  $(npm -v 2>/dev/null || echo missing)"  >&2
    vc --version ;;

  ""|-h|--help)
    usage ;;

  *)
    echo "vercel.sh: unknown command '$cmd' (try --help)" >&2
    exit 2 ;;
esac
