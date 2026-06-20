#!/usr/bin/env bash
# Talk to a remote MCP (Model Context Protocol) server with nothing but curl + jq.
# Speaks the Streamable-HTTP transport (JSON-RPC 2.0; handles both plain-JSON and
# SSE responses) and does the full handshake — initialize → notifications/initialized
# → the call — in one self-contained invocation, so every command is stateless from
# the agent's point of view. Servers + their url/token live in ./mcps.json.
#
# Usage:
#   mcp.sh list                              # list configured servers
#   mcp.sh tools <server>                    # discover a server's tools (+ input schemas)
#   mcp.sh call  <server> <tool> '<json>'    # invoke a tool; prints the text result
#   mcp.sh call  <server> <tool> --stdin     # …reading the JSON arguments from stdin
#   mcp.sh raw   <server> <method> '<json>'  # send any JSON-RPC method (resources/list, …)
#
# Config (./mcps.json, keep it git-ignored — it holds tokens):
#   { "servers": {
#       "linear": { "url": "https://mcp.linear.app/mcp", "token": "lin_..." },
#       "acme":   { "url": "https://acme.example/mcp",
#                   "token": "$ACME_TOKEN",            # whole-value $VAR / ${VAR} → env
#                   "headers": { "X-Org": "spirit" } }
#   } }
# A "token" becomes  Authorization: Bearer <token>;  use "headers" for anything else.
set -euo pipefail

MCPS="${MCPS_JSON:-mcps.json}"            # config path (workspace root by default)
PROTO="${MCP_PROTOCOL_VERSION:-2025-06-18}"
TIMEOUT="${MCP_TIMEOUT:-110}"             # per-request cap; sits just under the agent's 120s
UA="spirit-mcp/1.0"

die()  { printf 'mcp.sh: %s\n' "$1" >&2; exit "${2:-1}"; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1" 127; }
need curl; need jq

# Whole-value env expansion only ("$VAR" or "${VAR}") — never arbitrary eval.
expand_env() {
  local v="$1"
  if [[ "$v" =~ ^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$ ]]; then printf '%s' "${!BASH_REMATCH[1]:-}"; else printf '%s' "$v"; fi
}

# Populate globals (url, BASE_H[]) for a server named $1.
url=""; BASE_H=()
load_server() {
  local s="$1" entry token headers_json k v
  [ -f "$MCPS" ] || die "no $MCPS — copy skills/mcp/mcps.json.example to ./mcps.json and fill it in" 2
  jq -e . "$MCPS" >/dev/null 2>&1 || die "$MCPS is not valid JSON" 2
  entry="$(jq -c --arg s "$s" '.servers[$s] // empty' "$MCPS")"
  [ -n "$entry" ] || die "server '$s' not found in $MCPS (try: mcp.sh list)" 2
  url="$(jq -r '.url // empty' <<<"$entry")"
  [ -n "$url" ] || die "server '$s' has no \"url\"" 2
  token="$(expand_env "$(jq -r '.token // empty' <<<"$entry")")"
  headers_json="$(jq -c '.headers // {}' <<<"$entry")"

  BASE_H=(-H "Content-Type: application/json"
          -H "Accept: application/json, text/event-stream"
          -H "MCP-Protocol-Version: $PROTO"
          -H "User-Agent: $UA")
  [ -n "$token" ] && BASE_H+=(-H "Authorization: Bearer $token")
  while IFS=$'\t' read -r k v; do
    [ -n "$k" ] && BASE_H+=(-H "$k: $(expand_env "$v")")
  done < <(jq -r 'to_entries[]? | [.key, (.value|tostring)] | @tsv' <<<"$headers_json")
}

# Read a Streamable-HTTP body (plain JSON object, or an SSE stream) on stdin and
# print the single JSON-RPC response message it carries.
extract() {
  local body; body="$(cat)"
  if jq -e 'type=="object"' >/dev/null 2>&1 <<<"$body"; then
    printf '%s' "$body"
  else
    printf '%s\n' "$body" \
      | sed -n 's/^data:[[:space:]]\{0,1\}//p' \
      | jq -cR 'fromjson? | select(type=="object")' \
      | jq -sc 'map(select(.jsonrpc=="2.0" and (has("result") or has("error")))) | (last // {})'
  fi
}

# Full handshake + one method call. $1 server, $2 method, $3 params(json). Prints
# the JSON-RPC response object (with .result or .error).
request() {
  local server="$1" method="$2" params="${3:-}" hdrfile body init session sess=()
  [ -n "$params" ] || params='{}'
  load_server "$server"
  hdrfile="$(mktemp "${TMPDIR:-/tmp}/.mcp-hdr.XXXXXX")"; trap 'rm -f "$hdrfile"' RETURN

  init="$(jq -nc --arg pv "$PROTO" \
    '{jsonrpc:"2.0",id:1,method:"initialize",params:{protocolVersion:$pv,capabilities:{},clientInfo:{name:"spirit",version:"1.0"}}}')"
  body="$(curl -sS --connect-timeout 10 --max-time "$TIMEOUT" -D "$hdrfile" "${BASE_H[@]}" \
            -X POST "$url" --data-binary "$init")" || die "initialize request to '$server' failed (network/TLS?)"
  session="$(tr -d '\r' < "$hdrfile" | awk -F': *' 'tolower($1)=="mcp-session-id"{print $2; exit}')"
  init="$(extract <<<"$body")"
  if [ "$(jq -r 'has("error")' <<<"$init")" = true ]; then
    die "initialize failed: $(jq -rc '.error' <<<"$init")"
  fi
  [ -n "$session" ] && sess=(-H "Mcp-Session-Id: $session")

  # initialized notification — fire-and-forget (servers answer 202, no body).
  # ${sess[@]+...} guards an empty array under set -u (bash 3.2 / macOS).
  curl -sS --connect-timeout 10 --max-time 30 "${BASE_H[@]}" ${sess[@]+"${sess[@]}"} \
    -X POST "$url" --data-binary '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null 2>&1 || true

  local req
  req="$(jq -nc --arg m "$method" --argjson p "$params" '{jsonrpc:"2.0",id:2,method:$m,params:$p}')"
  body="$(curl -sS --connect-timeout 10 --max-time "$TIMEOUT" "${BASE_H[@]}" ${sess[@]+"${sess[@]}"} \
            -X POST "$url" --data-binary "$req")" || die "'$method' request to '$server' failed"
  extract <<<"$body"
}

cmd_list() {
  [ -f "$MCPS" ] || die "no $MCPS — copy skills/mcp/mcps.json.example to ./mcps.json" 2
  local n; n="$(jq '.servers | length' "$MCPS")"
  [ "$n" -gt 0 ] || { echo "no servers configured in $MCPS"; return; }
  jq -r '.servers | to_entries[] | "\(.key)\t→ \(.value.url)"' "$MCPS" | column -t -s $'\t' 2>/dev/null \
    || jq -r '.servers | to_entries[] | "\(.key)  →  \(.value.url)"' "$MCPS"
}

cmd_tools() {
  local server="${1:-}"; [ -n "$server" ] || die "usage: mcp.sh tools <server>" 64
  local out; out="$(request "$server" "tools/list" '{}')"
  [ "$(jq -r 'has("error")' <<<"$out")" = true ] && die "tools/list: $(jq -rc '.error' <<<"$out")"
  local count; count="$(jq -r '(.result.tools // []) | length' <<<"$out")"
  echo "$server: $count tool(s)"; echo
  jq -r '.result.tools[]? |
    "• \(.name)\n    \((.description // "") | gsub("\n";" "))\n    args: \((.inputSchema // {}) | tojson)\n"' <<<"$out"
}

cmd_call() {
  local server="${1:-}" tool="${2:-}" args="${3:-}"
  [ -n "$server" ] && [ -n "$tool" ] || die "usage: mcp.sh call <server> <tool> '<json-args>'|--stdin" 64
  case "$args" in
    --stdin) args="$(cat)";;
    "")      args="{}";;
  esac
  jq -e . >/dev/null 2>&1 <<<"$args" || die "tool arguments are not valid JSON: $args" 64

  local out; out="$(request "$server" "tools/call" \
    "$(jq -nc --arg n "$tool" --argjson a "$args" '{name:$n, arguments:$a}')")"
  [ "$(jq -r 'has("error")' <<<"$out")" = true ] && die "tools/call '$tool': $(jq -rc '.error' <<<"$out")"

  # Flatten the MCP content array into plain text; fall back to structuredContent / raw.
  local text
  text="$(jq -r '
    (.result.content // []) | map(
      if   .type=="text"     then .text
      elif .type=="image"    then "[image \(.mimeType // ""): \((.data // "")|length) base64 bytes]"
      elif .type=="audio"    then "[audio \(.mimeType // "")]"
      elif .type=="resource" then "[resource \(.resource.uri // "")]\n\(.resource.text // "")"
      else tojson end) | join("\n")' <<<"$out")"
  if [ -z "$text" ]; then
    text="$(jq -rc '.result.structuredContent // .result // empty' <<<"$out")"
  fi
  printf '%s\n' "$text"
  [ "$(jq -r '.result.isError // false' <<<"$out")" = true ] && exit 1 || true
}

cmd_raw() {
  local server="${1:-}" method="${2:-}" params="${3:-}"
  [ -n "$server" ] && [ -n "$method" ] || die "usage: mcp.sh raw <server> <method> ['<json-params>']" 64
  [ -n "$params" ] || params='{}'
  jq -e . >/dev/null 2>&1 <<<"$params" || die "params are not valid JSON: $params" 64
  request "$server" "$method" "$params" | jq .
}

case "${1:-}" in
  list)        shift; cmd_list "$@";;
  tools)       shift; cmd_tools "$@";;
  call)        shift; cmd_call "$@";;
  raw)         shift; cmd_raw "$@";;
  ""|-h|--help) sed -n '2,30p' "$0";;
  *)           die "unknown subcommand '$1' (list | tools | call | raw)" 64;;
esac
