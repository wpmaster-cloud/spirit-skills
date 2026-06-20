#!/usr/bin/env bash
# notes.sh — Obsidian-style markdown memory: a vault of linked .md notes that is
# the source of truth, plus a derived SQLite index for fast recall.
#
# The markdown files ($NOTES_DIR/*.md, frontmatter + ## Observations + ## Relations
# with [[wikilinks]]) are canonical; .index.db is a cache that `reindex` rebuilds.
# Full-text recall needs nothing but sqlite3; set BASE_URL+LLM_API_KEY (or
# MEMORY_EMBEDDER) to add semantic recall, fused with full-text by reciprocal rank.
#
#   notes.sh init                                     make the vault + index
#   notes.sh write "<title>" [--type T --tags a,b --importance 0.8 --body "..." \
#                             --link "rel:Target" ...]   (body also read from stdin)
#   notes.sh recall "<query>" [-k 8]                  hybrid search (reinforces hits)
#   notes.sh link "<src>" <relation> "<dst>"          add a relation edge
#   notes.sh backlinks "<title>"                      notes that point here
#   notes.sh recent [days]                            recently touched notes
#   notes.sh reflect [N]                              distill recent events -> a summary note
#   notes.sh daily "<text>"                           append a line to today's log
#   notes.sh audit                                    bloated / orphan / stale / broken-link report
#   notes.sh reindex                                  rebuild .index.db from the markdown
#   notes.sh stats
#
# Vault: NOTES_DIR (default ./notes). Embeddings: EMBED_MODEL (text-embedding-3-small),
# EMBED_DIM (1536), or MEMORY_EMBEDDER=<cmd> (text on $1 -> JSON number array).
set -euo pipefail

NOTES_DIR="${NOTES_DIR:-notes}"
DB="$NOTES_DIR/.index.db"
EMBED_MODEL="${EMBED_MODEL:-text-embedding-3-small}"
CHAT_MODEL="${CHAT_MODEL:-${MODEL:-gpt-4o-mini}}"

die()  { printf 'notes.sh: %s\n' "$*" >&2; exit 1; }
now()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
today(){ date -u +%Y-%m-%d; }
slug() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'; }
esc()  { printf '%s' "$1" | sed "s/'/''/g"; }              # single-quote -> SQL literal
sq()   { sqlite3 "$DB" "$@"; }
have_embed() { [ -n "${MEMORY_EMBEDDER:-}" ] || { [ -n "${BASE_URL:-}" ] && [ -n "${LLM_API_KEY:-}" ]; }; }

# text -> embedding as a space-separated float string ("" if embeddings are off)
embed_str() {
  have_embed || { printf ''; return; }
  if [ -n "${MEMORY_EMBEDDER:-}" ]; then "$MEMORY_EMBEDDER" "$1" | jq -r 'join(" ")'; return; fi
  curl -fsS "${BASE_URL%/}/embeddings" \
    -H "Authorization: Bearer ${LLM_API_KEY}" -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg m "$EMBED_MODEL" --arg i "$1" '{model:$m,input:$i}')" \
    | jq -r '.data[0].embedding | join(" ")' || die "embedding request failed"
}

chat() {  # user text -> assistant text (reflect)
  : "${BASE_URL:?set BASE_URL for reflect}" "${LLM_API_KEY:?set LLM_API_KEY for reflect}"
  curl -fsS "${BASE_URL%/}/chat/completions" \
    -H "Authorization: Bearer ${LLM_API_KEY}" -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg m "$CHAT_MODEL" --arg c "$1" '{model:$m,messages:[{role:"user",content:$c}]}')" \
    | jq -r '.choices[0].message.content // ""'
}

# --- markdown parsing -------------------------------------------------------
fm() {  # file key -> frontmatter value (first match, "" if none)
  awk -v k="$2" '
    NR==1 && $0!="---"{exit}
    NR==1{infm=1;next}
    infm && $0=="---"{exit}
    infm{ if (sub("^"k":[[:space:]]*","")) {print; exit} }' "$1"
}
body_of() {  # file -> everything after the frontmatter (whole file if none)
  awk '
    NR==1 && $0!="---"{nofm=1}
    nofm{print;next}
    NR==1{infm=1;next}
    infm && $0=="---"{infm=0;after=1;next}
    infm{next}
    after{print}' "$1"
}
norm_tags() { printf '%s' "$1" | tr -d '[]' | sed -E 's/[[:space:]]+//g'; }   # [a, b] -> a,b

FTS=0   # set by ensure_fts

ensure_schema() {
  mkdir -p "$NOTES_DIR/daily" "$NOTES_DIR/archive"
  sq <<'SQL'
CREATE TABLE IF NOT EXISTS notes(
  permalink TEXT PRIMARY KEY, path TEXT, title TEXT, type TEXT, tags TEXT,
  importance REAL DEFAULT 0.5, created TEXT, updated TEXT,
  access_count INTEGER DEFAULT 0, last_accessed TEXT, body TEXT);
CREATE TABLE IF NOT EXISTS links(src TEXT, rel TEXT, dst TEXT, dst_title TEXT);
CREATE TABLE IF NOT EXISTS vectors(permalink TEXT PRIMARY KEY, vec TEXT);
CREATE INDEX IF NOT EXISTS links_dst ON links(dst);
SQL
  if sqlite3 ":memory:" 'CREATE VIRTUAL TABLE t USING fts5(x);' >/dev/null 2>&1; then
    sq "CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(permalink UNINDEXED, title, body, tags);"
    FTS=1
  fi
}
detect_fts() { sq "SELECT name FROM sqlite_master WHERE name='notes_fts';" | grep -q . && FTS=1 || FTS=0; }

# Parse a note file and (re)write its rows in the index.
index_note() {
  local path="$1" pl title type tags imp created updated body
  pl="$(fm "$path" permalink)"; [ -n "$pl" ] || pl="$(slug "$(basename "$path" .md)")"
  title="$(fm "$path" title)"; [ -n "$title" ] || title="$(basename "$path" .md)"
  type="$(fm "$path" type)"; [ -n "$type" ] || type="note"
  tags="$(norm_tags "$(fm "$path" tags)")"
  imp="$(fm "$path" importance)"; case "$imp" in ''|*[!0-9.]*) imp="0.5" ;; esac
  created="$(fm "$path" created)"; [ -n "$created" ] || created="$(now)"
  updated="$(fm "$path" updated)"; [ -n "$updated" ] || updated="$(now)"
  body="$(body_of "$path")"
  sq <<SQL
DELETE FROM notes WHERE permalink='$(esc "$pl")';
INSERT INTO notes(permalink,path,title,type,tags,importance,created,updated,body)
VALUES('$(esc "$pl")','$(esc "$path")','$(esc "$title")','$(esc "$type")','$(esc "$tags")',
       $imp,'$(esc "$created")','$(esc "$updated")','$(esc "$body")');
DELETE FROM links WHERE src='$(esc "$pl")';
SQL
  [ "$FTS" = 1 ] && sq "DELETE FROM notes_fts WHERE permalink='$(esc "$pl")';
INSERT INTO notes_fts(permalink,title,body,tags) VALUES('$(esc "$pl")','$(esc "$title")','$(esc "$body")','$(esc "$tags")');"
  # edges: lines like "- relation [[Target]]" or a bare "[[Target]]"
  while IFS= read -r line; do
    [[ "$line" == *'[['*']]'* ]] || continue
    local target rel
    target="$(printf '%s' "$line" | sed -E 's/.*\[\[([^]]+)\]\].*/\1/')"
    rel="$(printf '%s' "$line" | sed -E 's/\[\[[^]]+\]\].*//; s/^[[:space:]]*-[[:space:]]*//; s/[[:space:]]+$//; s/^"//; s/"$//')"
    [ -n "$rel" ] || rel="links_to"
    rel="$(printf '%s' "$rel" | tr ' ' '_')"
    sq "INSERT INTO links(src,rel,dst,dst_title) VALUES('$(esc "$pl")','$(esc "$rel")','$(esc "$(slug "$target")")','$(esc "$target")');"
  done <<EOF
$body
EOF
  # optional embedding over title+body
  if have_embed; then
    local v; v="$(embed_str "$title
$body")"
    [ -n "$v" ] && sq "DELETE FROM vectors WHERE permalink='$(esc "$pl")';
INSERT INTO vectors(permalink,vec) VALUES('$(esc "$pl")','$(esc "$v")');"
  fi
}

cmd_init() {
  ensure_schema
  [ -f "$NOTES_DIR/MEMORY.md" ] || cat > "$NOTES_DIR/MEMORY.md" <<EOF
# Memory index

One line per durable note: \`- [Title](slug.md) — hook\`. Curated by \`reflect\`,
not a copy of the notes. Forward-links to notes not yet written are fine.
EOF
  echo "notes vault ready at $NOTES_DIR (fts=$FTS, embeddings=$(have_embed && echo on || echo off))"
}

cmd_write() {
  detect_fts
  local title="" type="note" tags="" imp="0.5" body="" links=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --type) type="$2"; shift 2 ;;
      --tags) tags="$(norm_tags "$2")"; shift 2 ;;
      --importance) imp="$2"; shift 2 ;;
      --body) body="$2"; shift 2 ;;
      --link) links+=("$2"); shift 2 ;;
      *) title="$1"; shift ;;
    esac
  done
  [ -n "$title" ] || die "write needs a title"
  [ -n "$body" ] || { [ -t 0 ] || body="$(cat)"; }            # stdin body if not a tty
  local pl path created; pl="$(slug "$title")"; path="$NOTES_DIR/$pl.md"
  created="$(now)"; [ -f "$path" ] && created="$(fm "$path" created)" && [ -n "$created" ] || created="$(now)"

  # assemble Relations from --link rel:Target (appended to any in --body)
  local rels=""
  for l in "${links[@]:-}"; do
    [ -n "$l" ] || continue
    rels+="- ${l%%:*} [[${l#*:}]]"$'\n'
  done

  {
    printf -- '---\ntitle: %s\ntype: %s\npermalink: %s\ntags: [%s]\nimportance: %s\ncreated: %s\nupdated: %s\n---\n\n' \
      "$title" "$type" "$pl" "$tags" "$imp" "$created" "$(now)"
    if [ -n "$body" ]; then printf '%s\n' "$body"; else printf '## Observations\n\n## Relations\n'; fi
    [ -n "$rels" ] && { case "$body" in *Relations*) : ;; *) printf '\n## Relations\n' ;; esac; printf '%s' "$rels"; }
  } > "$path"

  index_note "$path"
  echo "wrote $path"
}

cmd_link() {
  detect_fts
  [ $# -ge 3 ] || die "link needs: <src> <relation> <dst>"
  local src="$1" rel="$2" dst="$3" pl path
  pl="$(slug "$src")"; path="$NOTES_DIR/$pl.md"
  [ -f "$path" ] || die "no such note: $path (write it first)"
  grep -q '^## Relations' "$path" || printf '\n## Relations\n' >> "$path"
  printf -- '- %s [[%s]]\n' "$(printf '%s' "$rel" | tr ' ' '_')" "$dst" >> "$path"
  index_note "$path"
  echo "linked $src -[$rel]-> $dst"
}

cmd_backlinks() {
  [ -n "${1:-}" ] || die "backlinks needs a title"
  detect_fts
  local s; s="$(slug "$1")"
  sq "SELECT format('%s  -[%s]->  %s', n.title, l.rel, l.dst_title)
      FROM links l JOIN notes n ON n.permalink=l.src
      WHERE l.dst='$(esc "$s")' ORDER BY n.title;" 2>/dev/null \
    | grep . || echo "(no backlinks to '$1')"
}

cmd_recall() {
  detect_fts
  local query="" k=8
  while [ $# -gt 0 ]; do case "$1" in -k) k="$2"; shift 2 ;; *) query="$1"; shift ;; esac; done
  [ -n "$query" ] || die "recall needs a query"
  case "$k" in ''|*[!0-9]*) die "-k must be an integer" ;; esac

  # rank rows: "<permalink> <rrf_score>" from full-text and (optionally) vector
  local ranks; ranks="$(
    {
      if [ "$FTS" = 1 ]; then
        local ftsq; ftsq="$(printf '%s' "$query" | tr -cs '[:alnum:]' ' ' | sed -E 's/^ +//; s/ +$//; s/ +/ OR /g')"
        [ -n "$ftsq" ] && sq "SELECT permalink FROM notes_fts WHERE notes_fts MATCH '$(esc "$ftsq")' ORDER BY rank LIMIT 50;" 2>/dev/null
      else
        local like; like="%$(esc "$query")%"
        sq "SELECT permalink FROM notes WHERE body LIKE '$like' OR title LIKE '$like' LIMIT 50;" 2>/dev/null
      fi | awk '{printf "%s %.6f\n", $0, 1.0/(60+NR)}'

      if have_embed; then
        local qv; qv="$(embed_str "$query")"
        if [ -n "$qv" ]; then
          sq "SELECT permalink||' '||vec FROM vectors;" 2>/dev/null \
          | awk -v q="$qv" '
              BEGIN{n=split(q,qa," "); for(i=1;i<=n;i++)qn+=qa[i]*qa[i]; qn=sqrt(qn)}
              { pl=$1; d=0; vn=0; for(i=2;i<=NF;i++){d+=qa[i-1]*$i; vn+=$i*$i}
                if(vn>0&&qn>0) print pl, d/(qn*sqrt(vn)) }' \
          | sort -k2 -gr | head -50 | awk '{printf "%s %.6f\n", $1, 1.0/(60+NR)}'
        fi
      fi
    } | awk '{s[$1]+=$2} END{for(p in s) printf "%s %.6f\n", p, s[p]}' \
      | sort -k2 -gr | head -"$k"
  )"
  [ -n "$ranks" ] || { echo "(no matches for '$query')"; return; }

  local pl score
  while read -r pl score; do
    [ -n "$pl" ] || continue
    sq "UPDATE notes SET access_count=access_count+1, last_accessed='$(esc "$(now)")' WHERE permalink='$(esc "$pl")';"
    sq "SELECT format('#%s [%s | imp %s | score %s] %s  (%s)', permalink, type,
          round(importance,2), '$score', replace(substr(body,1,200),char(10),' '), path)
        FROM notes WHERE permalink='$(esc "$pl")';"
  done <<< "$ranks"
}

cmd_recent() {
  detect_fts
  local days="${1:-7}"
  find "$NOTES_DIR" -maxdepth 1 -name '*.md' ! -name 'MEMORY.md' -type f -mtime -"$days" 2>/dev/null \
    | while read -r f; do printf '%s\t%s\n' "$(fm "$f" updated)" "$f"; done \
    | sort -r | sed 's/\t/  /' | grep . || echo "(nothing modified in the last $days days)"
}

cmd_audit() {
  detect_fts
  echo "== audit =="
  printf 'notes: %s   links: %s\n' "$(sq 'SELECT count(*) FROM notes;')" "$(sq 'SELECT count(*) FROM links;')"
  echo "-- bloated (>300 lines):"
  find "$NOTES_DIR" -maxdepth 1 -name '*.md' -type f 2>/dev/null \
    | while read -r f; do n=$(wc -l < "$f"); [ "$n" -gt 300 ] && printf '  %5s  %s\n' "$n" "$f"; done | grep . || echo "  (none)"
  echo "-- orphans (no in- or out-links):"
  sq "SELECT '  '||title FROM notes n WHERE NOT EXISTS(SELECT 1 FROM links WHERE src=n.permalink)
        AND NOT EXISTS(SELECT 1 FROM links WHERE dst=n.permalink) ORDER BY title;" | grep . || echo "  (none)"
  echo "-- stale (task/episode, untouched > ${MEMORY_STALE_DAYS:-14}d):"
  sq "SELECT '  '||title||'  ('||coalesce(updated,created)||')' FROM notes
      WHERE type IN('task','episode')
        AND julianday('now')-julianday(coalesce(updated,created)) > ${MEMORY_STALE_DAYS:-14}
      ORDER BY updated;" | grep . || echo "  (none)"
  echo "-- broken links (target note missing):"
  sq "SELECT DISTINCT '  '||l.dst_title||'  <- '||n.title FROM links l JOIN notes n ON n.permalink=l.src
      WHERE NOT EXISTS(SELECT 1 FROM notes m WHERE m.permalink=l.dst) ORDER BY 1;" | grep . || echo "  (none)"
}

cmd_daily() {
  [ -n "${1:-}" ] || die "daily needs text"
  ensure_schema
  local f="$NOTES_DIR/daily/$(today).md"
  [ -f "$f" ] || printf -- '---\ntitle: %s\ntype: episode\n---\n\n' "$(today)" > "$f"
  printf -- '- %s %s\n' "$(date -u +%H:%M)" "$1" >> "$f"
  echo "logged to $f"
}

cmd_reflect() {
  detect_fts
  local lim="${1:-30}" material facts
  material="$(
    { find "$NOTES_DIR/daily" -name '*.md' -type f -mtime -2 2>/dev/null | sort | while read -r f; do body_of "$f"; done
      sq "SELECT body FROM notes WHERE type='episode' ORDER BY created DESC LIMIT $lim;" 2>/dev/null
    } | sed '/^[[:space:]]*$/d' | head -400 )"
  [ -n "$material" ] || { echo "nothing recent to reflect on"; return; }
  facts="$(chat "From these recent events and daily logs, extract the DURABLE, reusable facts worth long-term memory (decisions, preferences, lessons, identities, commitments). Skip transient/routine items. Reply with ONLY a JSON array of concise fact strings.
$material")"
  local body="## Observations"$'\n' n=0
  while IFS= read -r f; do [ -n "$f" ] || continue; body+="- [fact] $f"$'\n'; n=$((n+1)); done \
    < <(printf '%s' "$facts" | jq -r '.[]?' 2>/dev/null || true)
  [ "$n" -gt 0 ] || { echo "reflect found no durable facts"; return; }
  cmd_write "Reflection $(now)" --type summary --tags reflect --importance 0.7 --body "$body" >/dev/null
  echo "reflect distilled $n fact(s) into a summary note — review and fold key lines into MEMORY.md"
}

cmd_reindex() {
  rm -f "$DB"; ensure_schema
  local n=0
  while IFS= read -r f; do index_note "$f"; n=$((n+1)); done \
    < <(find "$NOTES_DIR" -maxdepth 1 -name '*.md' ! -name 'MEMORY.md' -type f 2>/dev/null)
  echo "reindexed $n note(s) into $DB (fts=$FTS, embeddings=$(have_embed && echo on || echo off))"
}

cmd_stats() {
  detect_fts
  sq "SELECT format('%-8s %4d   avg-imp %.2f', type, count(*), avg(importance)) FROM notes GROUP BY type ORDER BY count(*) DESC;"
  sq "SELECT format('TOTAL: %d notes, %d links, %d embedded', (SELECT count(*) FROM notes),
        (SELECT count(*) FROM links), (SELECT count(*) FROM vectors));"
}

[ -d "$NOTES_DIR" ] || case "${1:-}" in init|"") : ;; *) die "no vault at $NOTES_DIR — run: notes.sh init" ;; esac
case "${1:-}" in
  init)      shift; cmd_init "$@" ;;
  write)     shift; cmd_write "$@" ;;
  recall)    shift; cmd_recall "$@" ;;
  link)      shift; cmd_link "$@" ;;
  backlinks) shift; cmd_backlinks "$@" ;;
  recent)    shift; cmd_recent "$@" ;;
  reflect)   shift; cmd_reflect "$@" ;;
  daily)     shift; cmd_daily "$@" ;;
  audit)     shift; cmd_audit "$@" ;;
  reindex)   shift; cmd_reindex "$@" ;;
  stats)     shift; cmd_stats "$@" ;;
  ""|-h|--help) sed -n '2,33p' "$0" ;;
  *) die "unknown command: $1 (init write recall link backlinks recent reflect daily audit reindex stats)" ;;
esac
