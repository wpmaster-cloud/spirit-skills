---
name: vercel
requires: bash, curl, jq
description: >
  Deploy web apps and sites to Vercel on the free (Hobby) tier and get back a
  live, shareable URL. Primary path is the Vercel CLI (auto-installed via the
  install-runtimes skill, authenticated with a token); a curl-only REST fallback
  is documented for environments where Node can't run. Use whenever the user
  wants to deploy, ship, publish, host, or "put online" a website, web app,
  frontend, static site, Next.js / React / Vite / Astro / SvelteKit / Remix
  project, serverless API, or quick demo; when they ask for a public or
  shareable URL, or a preview vs production deployment; or when they mention
  Vercel by name. Also covers setting deployment env vars, viewing build logs,
  and listing recent deployments. Trigger phrases: "deploy", "ship it", "put
  this online", "host this", "make it live", "get me a public URL", "deploy to
  Vercel", "publish my site", "where can I see it live".
---

# Vercel (deploy on the free tier)

Point the skill at a folder, it returns a live URL. The CLI does the heavy
lifting (framework detection, `.vercelignore`, file hashing, the build); this
skill just wires up the token, makes sure the CLI exists, and surfaces the URL.

```
skills/vercel/
├── SKILL.md
├── config.env.example      # VERCEL_TOKEN (+ optional team / project pinning)
├── scripts/
│   └── vercel.sh           # deploy | env | logs | ls | whoami | ensure
└── references/
    └── api.md              # curl+jq REST fallback (no Node) + free-tier detail
```

## Quickstart

```bash
S=skills/vercel/scripts

bash $S/vercel.sh whoami                  # validate the token (cheap, do this first)
bash $S/vercel.sh deploy ./site --prod    # PUBLIC production deploy -> prints the live URL
bash $S/vercel.sh deploy ./site           # preview deploy (private: 401 to anon — see below)
bash $S/vercel.sh deploy ./site --public  # preview + make ALL urls publicly viewable
bash $S/vercel.sh ls                       # recent deployments for this project
bash $S/vercel.sh logs <deployment-url>    # build/runtime logs for one deployment
```

`stdout` of `deploy` is just the deployment URL (progress + the CLI's setup
chatter go to `stderr`), so it pipes cleanly:

```bash
url="$(bash $S/vercel.sh deploy ./site)" && echo "live at: $url"
```

## Subcommands (`scripts/vercel.sh`)

| Command | What it does |
|---|---|
| `deploy [path] [--prod] [--public] [-- <extra vercel flags>]` | Deploy `path` (default `.`). Preview by default; `--prod` for production (returns the **public** alias); `--public` disables deployment protection so preview urls are viewable too. Anything after `--` (e.g. `--archive=tgz`, `--force`) passes through to `vercel deploy`. |
| `env add NAME [target]` | Add an env var (`target` = `production`/`preview`/`development`, default `production`). Value from `$VALUE` or, if unset, read interactively by the CLI. |
| `env ls` | List the project's env vars. |
| `logs <url>` | `vercel inspect --logs` for a deployment URL. |
| `ls` | List recent deployments. |
| `whoami` | Print the token's account — the fastest token sanity check. |
| `ensure` | Bootstrap Node + the CLI and print versions; no deploy. Run once to pre-warm. |

## Credentials

Token from <https://vercel.com/account/tokens>. Resolution follows the usual
skill pattern — **the environment wins**; otherwise the script sources the first
existing config file (`$VERCEL_CONFIG`, `vercel/config.env`,
`skills/vercel/config.env`):

```bash
cp skills/vercel/config.env.example vercel/config.env   # then fill in, keep out of git
```

- `VERCEL_TOKEN` (required). The CLI reads it natively — **never pass it as
  `--token`**, which would leak it into shell history and process listings. The
  script exports it and never echoes it.
- `VERCEL_TEAM` (optional): a team slug. **Usually unnecessary** — the script
  auto-detects the token's team via the API and passes it as `--scope` (Vercel
  refuses to pick a scope non-interactively, and the personal account can't be
  used as `--scope`, so this matters). Set it explicitly only when the token can
  reach **more than one** team; the script will list them and ask you to choose.
  A Hobby/free team is still the free tier.
- `VERCEL_ORG_ID` + `VERCEL_PROJECT_ID` (optional, **both or neither**): pin to
  an existing project and skip the `.vercel/` link directory. Set only one and
  the script refuses with a clear error.

## Free tier (Hobby) — what to know before shipping

The free **Hobby** plan is generous but has real edges; surface them rather than
hitting them silently:

| Limit | Hobby allowance |
|---|---|
| Bandwidth | 100 GB / month |
| Build time | 100 build-minutes / month |
| Deployments | unlimited |
| Edge requests | 1M / month |
| Function invocations | 1M / month |
| Function compute | 4 CPU-hours / month |
| Image optimization | 5,000 transforms / month |
| Blob storage | 1 GB / month |

- **Hobby is non-commercial only.** If the project is clearly revenue-generating
  (a SaaS, a monetized blog, a store), say so — that needs the Pro plan, and
  deploying it to Hobby violates Vercel's terms. Don't quietly ship commercial
  work to the free tier.
- **Limits pause, they don't bill.** On the free tier there's no overage: hit a
  limit and the project pauses until the next cycle (the site goes offline) —
  Vercel won't charge you, but it also won't warn loudly. Mention this for
  anything that might get real traffic.

## Public URLs & deployment protection (read this — it bites)

By default a new project has **Deployment Protection ("Vercel Authentication")**
on, which means **the per-deployment `*-hash-*.vercel.app` hostnames return 401
to anyone not logged into the Vercel team** — including a plain `curl`. This is
the #1 "I deployed but it says 401" surprise. What's actually public:

| What you deploy | URL you get back | Anonymous visitor sees |
|---|---|---|
| `--prod` | the production **alias** `<project>.vercel.app` | ✅ public (200) |
| preview (default) | the deployment hostname `<project>-<hash>-<scope>.vercel.app` | ❌ 401 until they log in |
| preview `--public` | the deployment hostname | ✅ public (200) |

So the rule of thumb: **for a link you can actually share, use `--prod`** (the
script returns the public alias, not the protected per-deployment URL), or add
`--public` to a preview to switch protection off project-wide. The first-ever
deploy of a fresh project is auto-promoted to production by Vercel (it claims
the domain); deploys after that are previews unless you pass `--prod`.

## Gotchas

- **Node isn't baked into the agent image.** The script bootstraps it via the
  `install-runtimes` skill (`scripts/get.sh node`) on first use, then installs
  the `vercel` CLI globally into a writable prefix. The one failure mode is
  **musl + arm64** (Alpine on ARM), where a prebuilt Node musl build is often
  absent — see `skills/install-runtimes/SKILL.md`. The deployed server image is
  glibc, so this normally just works.
- **Persist the toolchain.** By default Node + the CLI land in `~/.local`, which
  may not survive a pod replacement. Set `RUNTIME_PREFIX=/work/tools` (and
  optionally `VERCEL_NPM_PREFIX=/work/tools`) so they live on the agent's
  writable, committable path and aren't re-downloaded every cold start.
- **Egress is HTTPS:443** to `vercel.com`, `api.vercel.com`, and
  `registry.npmjs.org` (for the install). Behind the VPN-egress pod, both `npm`
  and the Vercel CLI honor `HTTPS_PROXY`/`HTTP_PROXY`, which are already baked in
  — no extra config.
- **Thousands of files** (e.g. an un-ignored `node_modules`) can hit Vercel's
  per-deploy file limit. Add a `.vercelignore`, or deploy with
  `-- --archive=tgz` to upload one compressed blob.
- **Build vs deploy.** `deploy` uploads your source and Vercel builds it
  remotely (framework auto-detected). To build locally instead — useful for
  debugging a build — run `vercel build` then `deploy -- --prebuilt`.

## No-Node fallback (curl + jq)

If Node genuinely can't run, you can still deploy with nothing but `curl`,
`jq`, and `shasum`: hash each file, upload to `/v2/files`, then `POST
/v13/deployments`. The full worked recipe (static and framework builds, plus
polling for `READY`) is in **`references/api.md`**.
