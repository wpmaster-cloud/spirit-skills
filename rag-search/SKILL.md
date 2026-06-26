---
name: rag-search
description: Semantic recall over this agent's own indexed notes, via the indexer service.
---

# rag-search

Retrieve the passages most relevant to a query from **your own** notes — the
indexer maintains a private vector store over your folder subtree (and only
yours). Use it when grep/ripgrep keyword search isn't enough and you want
meaning-based recall of what you've written or collected.

## Usage

Run the bundled script from your workspace:

    skills/rag-search/rag_search "your query" [k]

- `k` (optional, default `5`) — how many passages to return.
- Output is JSON: `{"results":[{"path","ord","text","score"}, ...]}` — `path`
  is relative to your home, `score` is cosine similarity (1 = closest).

## Notes

- It uses the server-injected `INDEXER_URL` + `RAG_TOKEN`, so it works only when
  the indexer service is deployed. If it isn't, the script says so and exits
  non-zero — fall back to `rg`/`grep` over your files.
- The indexer embeds the query for you; you never handle keys or vectors.
