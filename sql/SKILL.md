---
name: sql
requires: sqlite3, psql
description: >
  Query and manage SQL databases — SQLite and PostgreSQL — with one small CLI over
  the baked sqlite3 and psql (postgresql-client) clients. Use whenever the user
  wants to run a SQL query, connect to a Postgres or SQLite database, inspect a
  schema or list tables, load a CSV into a table or export a query to CSV, dump or
  back up a database, or do ad-hoc data work against a real DB rather than a
  pandas/Python dataframe. Picks the backend automatically from a DB_URL. Trigger
  phrases: "run this query", "query the database", "connect to postgres", "psql",
  "sqlite", "select * from", "what tables are in", "show me the schema", "import
  this csv into", "export to csv", "dump the database", "back up the db". For the
  agent's own pgvector long-term memory use the `memory` skill; for CSV/dataframe
  analysis without a database use `data-analysis`.
---

# sql — one CLI over SQLite + PostgreSQL

`scripts/db.sh` is a thin, safe wrapper over the two database clients the image
ships. It chooses the backend from a **`DB_URL`** so the same commands work
against either:

```bash
export DB_URL="sqlite://$PWD/app.db"                      # SQLite (a file in your folder)
export DB_URL=postgres://user:pass@host:5432/dbname       # PostgreSQL
```

The connection string is a credential — set it in the environment (inherited by
`run_command`, never printed), not on the command line where it lands in the
transcript. `psql` also reads the standard `PGPASSWORD`/`~/.pgpass` if you prefer.

```
skills/sql/
├── SKILL.md
└── scripts/
    └── db.sh      # query | tables | schema | import-csv | export-csv | dump | shell
```

All paths are relative to **your own folder** (the `run_command` CWD).

## Subcommands

```bash
db=skills/sql/scripts/db.sh

# run SQL (multiple statements ok; reads from --file or stdin too)
bash $db query "select count(*) from users where active"
bash $db query --file migrations/001.sql
echo "select now()" | bash $db query --stdin

# explore
bash $db tables                 # list tables
bash $db schema                 # all table DDL
bash $db schema users           # one table's columns/DDL

# CSV in/out
bash $db import-csv users data/users.csv     # header row → column names if table is new
bash $db export-csv "select id,email from users" out.csv   # omit the file to stream to stdout

# whole-database dump (SQLite: .dump SQL;  Postgres: pg_dump)
bash $db dump backup.sql
```

## Backend differences worth knowing

- **SQLite is a plain file.** `DB_URL=sqlite:///abs/path.db` (three slashes →
  absolute) or `sqlite:relative.db`. It writes in place, so — unlike Postgres — it
  is **unaffected by the Landlock jail** as long as the file lives inside the
  agent's own folder. It's the right default for an agent's own structured data.
- **Postgres is a server you connect to.** `db.sh` only *talks* to it; it doesn't
  run one. Standing up a local Postgres inside the agent **does not work**: it
  `rename()`s across dirs, which the Landlock jail denies → `EXDEV`. There is no
  setting to turn that off — the server hardcodes the jail on every run it starts,
  so point `DB_URL` at an external Postgres instead. (The pod NetworkPolicy allows
  egress on 53/80/443 only, so reaching one on 5432 needs an operator to open the
  port.) The `memory` skill hits exactly this.
- **`import-csv`**: on SQLite a *new* table takes its column names from the CSV
  header; an *existing* table appends rows (header included — pre-create the table
  or drop the header first if that matters). On Postgres the table must already
  exist (`\copy ... WITH (FORMAT csv, HEADER true)`).

## Safety

- Destructive SQL (`DROP`, `DELETE`, `TRUNCATE`, `UPDATE` without a `WHERE`) does
  exactly what you tell it. On a database you don't own, **read first** (`tables`,
  `schema`, a `SELECT`) and confirm with the user before mutating.
- `dump` is the cheap insurance before any risky change — take one first.
- Errors stop the batch: Postgres runs with `ON_ERROR_STOP=1`, so a failed
  statement aborts rather than silently continuing.
