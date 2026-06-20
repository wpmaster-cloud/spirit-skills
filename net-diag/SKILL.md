---
name: net-diag
requires: bind-tools, openssl, curl
description: >
  Network, DNS, and TLS diagnostics from the agent using the baked dig/host/nslookup
  (bind-tools), openssl, and curl. Use whenever the user wants to debug connectivity
  or DNS, look up a domain's records, check DNS propagation across resolvers, inspect
  a TLS/SSL certificate or its expiry, test whether a host:port is reachable, see what
  public/egress IP the agent's traffic exits from, trace why a request fails, or
  generally answer "is X up / resolvable / reachable / does its cert expire soon".
  Also the go-to for verifying the agent's own egress (it exits a rotating NordVPN
  proxy pool, not the node IP). Trigger phrases: "dns", "dig", "nslookup", "resolve",
  "is <host> up", "can you reach", "port open", "ssl certificate", "tls", "cert
  expiry", "https not working", "dns propagation", "what's my ip", "egress ip",
  "check connectivity", "why can't I connect".
---

# net-diag — DNS / TLS / connectivity probes

Deterministic network checks wrapping the tools baked into the image. Each script
prints a focused, human-readable report and exits non-zero on failure, so you can
branch on the result.

```
skills/net-diag/
├── SKILL.md
└── scripts/
    ├── dns.sh      # record lookups + cross-resolver propagation (dig)
    ├── tls.sh      # certificate subject/issuer/SAN/expiry + protocol (openssl)
    ├── port.sh     # TCP reachability without netcat (bash /dev/tcp)
    └── egress.sh   # the agent's outbound public IP + geo (curl)
```

Paths are relative to the **workspace root** (the `run_command` CWD).

## DNS — `dns.sh`

```bash
# summary across the common record types (A/AAAA/CNAME/MX/NS/TXT):
bash skills/net-diag/scripts/dns.sh example.com

# one record type:
bash skills/net-diag/scripts/dns.sh example.com MX

# propagation: same query against Cloudflare/Google/Quad9/OpenDNS side by side
# (mismatched answers ⇒ a record is still propagating, or split-horizon DNS):
bash skills/net-diag/scripts/dns.sh app.example.com A --propagate
```

## TLS / certificates — `tls.sh`

```bash
bash skills/net-diag/scripts/tls.sh example.com            # defaults to :443
bash skills/net-diag/scripts/tls.sh mail.example.com:465
bash skills/net-diag/scripts/tls.sh --servername api.x.com edge.x.com:443  # SNI override
```

Prints subject, issuer, serial, the validity window, **days-to-expiry** (flagging
`EXPIRED` / `EXPIRES SOON` under 14 days), the SAN list, and the negotiated
protocol/cipher. Great for "is this cert about to lapse" and "does the SAN cover
this hostname".

## Reachability — `port.sh`

```bash
# check one or more TCP ports (no nc in the image — uses bash /dev/tcp):
bash skills/net-diag/scripts/port.sh example.com 22 80 443
# PORT_TIMEOUT=2 bash ... to shorten the per-port wait
```

Each line is `host:port  open` or `host:port  closed/filtered`. This tests the TCP
handshake only — "open" means something is listening and reachable *from the
agent's current egress*, not that the service behind it is healthy.

## Egress IP — `egress.sh`

```bash
bash skills/net-diag/scripts/egress.sh
```

Shows the public IP the world sees as the source of the agent's traffic, plus org
and rough location. On a **VPN-enabled** agent (the `:vpn` image) this should be a
**NordVPN** address — the in-image OpenVPN tunnel carries all egress — **not** the
host/node IP. The exit IP is stable per pod and changes only when the pod re-dials
(it does not vary per connection). Pass `NODE_IP=<host ip>` to have the script warn
when egress matches the host (i.e. the tunnel is down). A `connect()` that fails
outright usually means the tunnel is down — the killswitch fails closed (see
`ops/CLAUDE.md` → "Egress VPN").

## Notes

- These are read-only probes; nothing here changes remote state.
- `dig`/`openssl` honour the same forced egress as everything else, so a result is
  always "as seen from the agent's current exit IP" — relevant when DNS is
  split-horizon or a firewall is source-IP aware.
- For driving a remote host (not just probing it), use the **remote-ops** skill.
