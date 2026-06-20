---
name: mcp
requires: curl, jq
description: >
  Call tools on any remote MCP (Model Context Protocol) server using nothing but
  curl + jq — no SDK, no harness changes. Use whenever the user wants the agent to
  use an MCP server / MCP tools, connect to an MCP endpoint, list or call the tools
  a server exposes, or integrate a service that ships an MCP server (Linear, GitHub,
  Sentry, Notion, a custom internal MCP, etc.). Servers and their url/token live in
  a ./mcps.json file the agent reads. Speaks the Streamable-HTTP transport (JSON-RPC
  2.0; handles plain-JSON and SSE responses) and does the full handshake per call.
  Trigger phrases: "mcp", "mcp server", "mcp tool", "model context protocol",
  "connect to <service> over mcp", "use the <service> mcp", "list mcp tools",
  "call an mcp tool", "mcps.json".
---

# mcp — use remote MCP servers with curl

An MCP server exposes **tools** (and resources/prompts) over JSON-RPC 2.0. This
skill talks to the **Streamable-HTTP** transport directly with `curl` — the same
request/response shape every other skill here uses. There is **no native MCP tool**
in the runtime; you discover and invoke MCP tools yourself by running `mcp.sh`,
exactly as you run any other command. That keeps it lazy: a server is only contacted
when a task actually needs it.

```
skills/mcp/
├── SKILL.md
├── mcps.json.example
└── scripts/mcp.sh
```

Paths are relative to the **workspace root**.

## Setup

Configure the servers you can reach in `./mcps.json` at the workspace root:

```bash
cp skills/mcp/mcps.json.example mcps.json     # then edit it
echo 'mcps.json' >> .gitignore                # it holds tokens — keep it out of git
```

```json
{
  "servers": {
    "linear": { "url": "https://mcp.linear.app/mcp", "token": "$LINEAR_MCP_TOKEN" },
    "acme":   { "url": "https://acme.example/mcp",
                "token": "paste-or-$ENV_VAR",
                "headers": { "X-Org-Id": "spirit" } }
  }
}
```

- **`url`** — the server's MCP endpoint (Streamable HTTP). Required.
- **`token`** — sent as `Authorization: Bearer <token>`. Optional. A whole-value
  `$VAR` / `${VAR}` is read from the environment, so a secret can stay in env
  rather than the file.
- **`headers`** — any extra request headers (e.g. a non-Bearer auth scheme, an org
  id). Values support the same `$VAR` expansion.

Only **bearer / API-key auth** is supported. Full OAuth (browser redirect) is out
of scope — if a server only does interactive OAuth, mint a long-lived token in its
dashboard and put that in `token`.

## Use

```bash
mcp=skills/mcp/scripts/mcp.sh

bash $mcp list                                   # which servers are configured
bash $mcp tools linear                           # discover a server's tools + arg schemas
bash $mcp call  linear list_issues '{"teamId":"ENG","limit":5}'
echo "$BIG_JSON" | bash $mcp call linear create_issue --stdin   # large args via stdin
```

The normal flow for a new server is **`tools` then `call`**: read the tool list
(each entry prints its name, description, and JSON-Schema for arguments), build the
arguments to match that schema, then `call` it. `tools` is cheap — always check the
schema before calling rather than guessing argument names.

`call` flattens the server's result into plain text (text parts joined; images and
resources noted by type) and prints it. If the tool reports an error
(`isError:true`) the command exits non-zero with the message on stdout.

For methods beyond tools — resources, prompts, anything in the spec — use `raw`,
which prints the JSON-RPC response untouched:

```bash
bash $mcp raw linear resources/list '{}'
bash $mcp raw linear prompts/list   '{}'
```

## How it works (so you can debug)

Each `mcp.sh` invocation is a complete, stateless MCP session: it POSTs
`initialize`, captures the `Mcp-Session-Id` response header, sends the
`notifications/initialized` notification, then sends your `tools/call` (or other
method) — re-handshaking every call rather than holding a connection. Responses
arrive as either plain JSON or an SSE stream (`data:` lines); both are parsed.

## Notes & failure modes

- **`server '<x>' not found`** → it isn't in `mcps.json` (run `mcp.sh list`).
- **`initialize failed` / HTTP/TLS error** → wrong `url`, expired/absent `token`,
  or the endpoint isn't reachable from this pod's egress.
- **`-32601 method not found`** (via `raw`) → the server doesn't implement that
  method; check `tools` for what it does expose.
- **Long calls:** a request is capped at `MCP_TIMEOUT` (default 110s, just under the
  agent's 120s `run_command` limit). Raise it with `MCP_TIMEOUT=300 bash $mcp call …`
  for a genuinely slow tool — but the run_command cap still applies, so prefer
  servers that answer quickly.
- **Protocol version:** defaults to `2025-06-18`; override with
  `MCP_PROTOCOL_VERSION=…` if a server demands a different one.
- Pair with **cron** to poll an MCP-backed service on a schedule, or with a
  notification skill (webhooks/telegram) to surface what a tool returns.
- This skill covers **remote HTTP** MCP servers only — local `stdio` servers
  (launched as a subprocess) are a different transport and are not supported here.
