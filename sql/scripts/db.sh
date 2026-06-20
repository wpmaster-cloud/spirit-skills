#!/usr/bin/env bash
# One CLI over SQLite and PostgreSQL. Backend is chosen from DB_URL:
#   export DB_URL=sqlite:///work/app.db                 # absolute file (three slashes)
#   export DB_URL=sqlite:relative.db                    # relative file
#   export DB_URL=postgres://user:pass@host:5432/dbname # PostgreSQL
# Subcommands: query | tables | schema | import-csv | export-csv | dump | shell
set -euo pipefail

url="${DB_URL:-}"
[ -n "$url" ] || { echo "db.sh: set DB_URL (sqlite:///path.db or postgres://user:pass@host/db)" >&2; exit 2; }

# --- resolve backend ----------------------------------------------------------
backend=""; sqpath=""
case "$url" in
  sqlite:///*) backend=sqlite; sqpath="/${url#sqlite:///}";;
  sqlite://*)  backend=sqlite; sqpath="${url#sqlite://}";;
  sqlite:*)    backend=sqlite; sqpath="${url#sqlite:}";;
  postgres://*|postgresql://*) backend=pg;;
  *) echo "db.sh: unrecognized DB_URL scheme (use sqlite: or postgres://)" >&2; exit 2;;
esac
if [ "$backend" = sqlite ]; then
  command -v sqlite3 >/dev/null || { echo "db.sh: sqlite3 not found" >&2; exit 127; }
else
  command -v psql >/dev/null || { echo "db.sh: psql not found (apk add postgresql-client)" >&2; exit 127; }
fi

cmd="${1:-}"; shift || true
[ -n "$cmd" ] || { echo "usage: db.sh query|tables|schema|import-csv|export-csv|dump|shell ..." >&2; exit 2; }

run_sql() {  # $1 = SQL text
  if [ "$backend" = sqlite ]; then
    sqlite3 -header -column "$sqpath" "$1"
  else
    psql "$url" -v ON_ERROR_STOP=1 -P pager=off -c "$1"
  fi
}

case "$cmd" in
  query)
    sql=""
    case "${1:-}" in
      --file) sql="$(cat "${2:?--file needs a path}")";;
      --stdin) sql="$(cat)";;
      "") echo "db.sh query: pass SQL, --file PATH, or --stdin" >&2; exit 2;;
      *) sql="$1";;
    esac
    run_sql "$sql";;

  tables)
    if [ "$backend" = sqlite ]; then sqlite3 "$sqpath" '.tables'
    else psql "$url" -P pager=off -c '\dt'; fi;;

  schema)
    tbl="${1:-}"
    if [ "$backend" = sqlite ]; then sqlite3 "$sqpath" ".schema $tbl"
    elif [ -n "$tbl" ]; then psql "$url" -P pager=off -c "\\d $tbl"
    else psql "$url" -P pager=off -c '\d+'; fi;;

  import-csv)
    tbl="${1:?usage: db.sh import-csv TABLE FILE.csv}"; file="${2:?csv file required}"
    [ -f "$file" ] || { echo "db.sh: no such file: $file" >&2; exit 1; }
    if [ "$backend" = sqlite ]; then
      sqlite3 "$sqpath" ".mode csv" ".import --csv \"$file\" \"$tbl\""
      echo "imported $file → $tbl (sqlite)"
    else
      psql "$url" -v ON_ERROR_STOP=1 -c "\\copy $tbl FROM '$file' WITH (FORMAT csv, HEADER true)"
    fi;;

  export-csv)
    sql="${1:?usage: db.sh export-csv \"SQL\" [out.csv]}"; out="${2:-}"
    if [ "$backend" = sqlite ]; then
      if [ -n "$out" ]; then sqlite3 -csv -header "$sqpath" "$sql" > "$out"; echo "wrote $out"
      else sqlite3 -csv -header "$sqpath" "$sql"; fi
    else
      copy="\\copy ($sql) TO STDOUT WITH (FORMAT csv, HEADER true)"
      if [ -n "$out" ]; then psql "$url" -v ON_ERROR_STOP=1 -c "$copy" > "$out"; echo "wrote $out"
      else psql "$url" -v ON_ERROR_STOP=1 -c "$copy"; fi
    fi;;

  dump)
    out="${1:-}"
    if [ "$backend" = sqlite ]; then
      if [ -n "$out" ]; then sqlite3 "$sqpath" .dump > "$out"; echo "wrote $out"
      else sqlite3 "$sqpath" .dump; fi
    else
      command -v pg_dump >/dev/null || { echo "db.sh: pg_dump not found" >&2; exit 127; }
      if [ -n "$out" ]; then pg_dump "$url" > "$out"; echo "wrote $out"
      else pg_dump "$url"; fi
    fi;;

  shell)
    # Interactive REPL — only useful if the agent run has a TTY (rare). Mostly here
    # for a human exec'ing into the pod.
    if [ "$backend" = sqlite ]; then exec sqlite3 "$sqpath"; else exec psql "$url"; fi;;

  *) echo "db.sh: unknown subcommand '$cmd'" >&2; exit 2;;
esac
