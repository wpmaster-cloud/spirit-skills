# Vercel REST API — deploy with curl + jq only (no Node)

When Node genuinely can't run, deploy with nothing but `curl`, `jq`, and a SHA
tool (`sha1sum`, or `shasum` on macOS). The flow is always: **upload every file
by its SHA-1, then create a deployment that references those SHAs.** Vercel
builds remotely, exactly like the CLI — you just assemble the request yourself.

- Base: `https://api.vercel.com`
- Auth: `Authorization: Bearer $VERCEL_TOKEN` on every call
- Teams: append `?teamId=<id>` (or `&slug=<slug>`) to each request
- Token: <https://vercel.com/account/tokens>

## 1. Upload each file — `POST /v2/files`

One request per file. The body is the raw bytes; the SHA-1 of those bytes goes
in the `x-vercel-digest` header. Re-uploading an already-known SHA is a cheap
no-op, so it's safe to upload everything every time.

```bash
sha_of() { if command -v sha1sum >/dev/null; then sha1sum "$1" | cut -d' ' -f1
           else shasum -a 1 "$1" | cut -d' ' -f1; fi; }

API=https://api.vercel.com
upload_one() { # upload_one <path>
  local f="$1" sha; sha="$(sha_of "$f")"
  curl -fsS -X POST "$API/v2/files" \
    -H "Authorization: Bearer $VERCEL_TOKEN" \
    -H "x-vercel-digest: $sha" \
    -H "Content-Type: application/octet-stream" \
    --data-binary @"$f" >/dev/null
}
```

## 2. Build the file manifest

Each entry is `{file: <relative path>, sha, size}`. Mirror whatever you
uploaded; skip junk (`.git`, `node_modules`, `.vercel`).

```bash
manifest() { # manifest <dir>  -> JSON array on stdout
  ( cd "$1" && find . -type f \
      -not -path './.git/*' -not -path './node_modules/*' -not -path './.vercel/*' \
    | while read -r f; do
        rel="${f#./}"; sha="$(sha_of "$f")"; size="$(wc -c <"$f" | tr -d ' ')"
        jq -nc --arg file "$rel" --arg sha "$sha" --argjson size "$size" \
          '{file:$file, sha:$sha, size:$size}'
      done | jq -s . )
}
```

## 3. Create the deployment — `POST /v13/deployments`

```bash
deploy_dir() { # deploy_dir <dir> <project-name> [--prod]
  local dir="$1" name="$2" target="" files
  [ "${3:-}" = "--prod" ] && target="production"
  ( cd "$dir" && find . -type f -not -path './.git/*' -not -path './node_modules/*' \
      -not -path './.vercel/*' | while read -r f; do upload_one "$f"; done )
  files="$(manifest "$dir")"
  jq -nc --arg name "$name" --argjson files "$files" --arg target "$target" \
    '{name:$name, files:$files, projectSettings:{framework:null}}
     + (if $target != "" then {target:$target} else {} end)' \
  | curl -fsS -X POST "$API/v13/deployments" \
      -H "Authorization: Bearer $VERCEL_TOKEN" \
      -H "Content-Type: application/json" \
      --data-binary @-
}
```

The response includes `id` and a preview `url` immediately, but the build may
still be running — poll for readiness (step 4).

### Static vs framework builds

- **Static** (plain HTML/CSS/JS): `projectSettings:{framework:null}` and upload
  the files as-is — Vercel serves them directly, no build.
- **Framework** (Next.js, Vite, Astro, …): set
  `projectSettings:{framework:"nextjs"}` (or the right slug) and upload your
  **source**. Vercel runs the build remotely. You can also pin
  `buildCommand` / `outputDirectory` / `installCommand` inside `projectSettings`.
- **Tiny sites** can skip step 1 entirely by inlining content:
  `files:[{file:"index.html", data:"<!doctype html>…"}]` — no SHA upload needed.

## 4. Poll for READY — `GET /v13/deployments/<id>`

```bash
wait_ready() { # wait_ready <deployment-id>
  local id="$1" state
  for _ in $(seq 1 60); do
    state="$(curl -fsS "$API/v13/deployments/$id" \
      -H "Authorization: Bearer $VERCEL_TOKEN" | jq -r '.readyState')"
    case "$state" in
      READY)               echo "ready"; return 0 ;;
      ERROR|CANCELED)      echo "build $state" >&2; return 1 ;;
      *)                   sleep 5 ;;   # QUEUED / BUILDING / INITIALIZING
    esac
  done
  echo "timed out waiting for READY" >&2; return 1
}
```

## End to end

```bash
resp="$(deploy_dir ./site my-app --prod)"
id="$(printf '%s' "$resp"  | jq -r '.id')"
url="$(printf '%s' "$resp" | jq -r '.url')"     # e.g. my-app-xxxx.vercel.app
wait_ready "$id" && echo "https://$url"
```

## Notes & limits

- **Free (Hobby) tier:** 100 GB bandwidth, 100 build-min, unlimited deploys per
  month; non-commercial only; limits pause (never bill) the project. Full table
  in `../SKILL.md`.
- **401 on the deployment URL?** Deployment Protection is on by default — the
  `*-hash-*.vercel.app` hostnames require login; only the production alias is
  public. Make a deployment public by patching the project:
  `curl -X PATCH "$API/v9/projects/<id>?teamId=<id>" -H "Authorization: Bearer $VERCEL_TOKEN" -d '{"ssoProtection":null}'`.
  See `../SKILL.md` → "Public URLs & deployment protection".
- **Scope:** if the token can see a team, pass `?teamId=<id>` (or `&slug=`) on
  every call, exactly as the CLI path resolves `--scope`.
- **Files limit:** a single deploy caps the number of files. For large trees,
  prefer the CLI's `--archive=tgz`; the raw API has no archive shortcut, so trim
  with the `find` excludes above.
- **HTTP codes:** `401` bad/expired token, `403` wrong scope (set `teamId`),
  `429` slow down. Read the JSON `error.message` — it's specific.
- Docs: <https://vercel.com/docs/rest-api/reference/endpoints/deployments/create-a-new-deployment>
  and `.../upload-deployment-files`.
