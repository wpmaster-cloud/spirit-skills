---
name: net-diag
requires: dig, openssl, curl
description: >
  Network, DNS, and TLS diagnostics from the agent using the baked dig/host/nslookup
  (bind-tools), openssl, and curl. Use whenever the user wants to debug connectivity
  or DNS, look up a domain's records, check DNS propagation across resolvers, inspect
  a TLS/SSL certificate or its expiry, test whether a host:port is reachable, see what
  public/egress IP the agent's traffic exits from, trace why a request fails, or
  generally answer "is X up / resolvable / reachable / does its cert expire soon".
  Also the go-to for verifying the agent's own egress (it exits the cluster node's
  IP). Trigger phrases: "dns", "dig", "nslookup", "resolve",
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
    ├── port.sh     # TCP reachability (bash /dev/tcp — no extra deps)
    └── egress.sh   # the agent's outbound public IP + geo (curl)
```

Paths are relative to **your own folder** (the `run_command` CWD).

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
# check one or more TCP ports (uses bash /dev/tcp — no extra deps):
bash skills/net-diag/scripts/port.sh example.com 22 80 443
# PORT_TIMEOUT=2 bash ... to shorten the per-port wait
```

Each line is `host:port  open` or `host:port  closed/filtered`. This tests the TCP
handshake only — "open" means something is listening and reachable *from the
agent's current egress*, not that the service behind it is healthy.

> **Read `closed/filtered` carefully: it is usually the cluster, not the host.**
> The pod's NetworkPolicy (`ops/spirit.yaml`) permits egress on **53, 80 and 443
> only**. Every other port — 22, 5432, 6379, … — is dropped on the way out, so it
> reports `closed/filtered` no matter how healthy the remote service is. A probe of
> 80/443 is a real answer; a probe of anything else mostly measures the
> NetworkPolicy. Opening a port is an operator change to that manifest.

## Egress IP — `egress.sh`

```bash
bash skills/net-diag/scripts/egress.sh
```

Shows the public IP the world sees as the source of the agent's traffic, plus org
and rough location. There is **no VPN, proxy pool, or tunnel** in front of the
agent: traffic exits as the **cluster node's own public IP**, so seeing the node's
address is the *correct* result, not a fault. It is stable for as long as the pod
stays on that node — which is what makes it the address to hand a remote admin for
an IP allowlist. If `egress.sh` fails to connect at all, the path itself is broken
(DNS, or the NetworkPolicy above), not a dropped tunnel.

## Notes

- These are read-only probes; nothing here changes remote state.
- Every answer is "as seen from inside the cluster" — resolved by the pod's DNS,
  sourced from the node's egress IP. That matters when DNS is split-horizon or a
  remote firewall is source-IP aware.
- For driving a remote host (not just probing it), use the **remote-ops** skill.
