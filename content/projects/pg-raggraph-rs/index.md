---
title: "pg-raggraph-rs"
date: 2026-07-01
draft: false
tags: ["rust", "postgresql", "pgrx", "graphrag", "performance", "rag"]
summary: "The Rust performance line for pg-raggraph: a real pgrx extension with async background-worker ingest and hybrid retrieval, plus a sidecar mode for managed Postgres where you can't load an extension at all."
externalUrl: "https://github.com/yonk-labs/pg-raggraph-rs"
---

**pg-raggraph-rs** is the Rust line of [pg-raggraph](https://github.com/yonk-labs/pg-raggraph) — the same GraphRAG-in-PostgreSQL model, packaged as a single `pgrx` extension instead of an importable library. Three SQL statements get you from ingest to a grounded answer:

```sql
CREATE EXTENSION pg_raggraph;
SELECT pgrg.ingest('docs/');
SELECT * FROM pgrg.ask('what changed in the auth module?');
```

## What's shipped (0.1.0-alpha.3)

The foundation, the retrieval engine, and the async ingest pipeline are in place: schema and namespaces, hybrid retrieval (`pgrg.query`), a background worker pool with queue-backed async ingest (`pgrg.ingest_text`, `pgrg.ingest_bytes`), [chunkshop](https://github.com/yonk-labs/chunkshop) wired in as the canonical chunker, an ONNX-backed embedding model loaded once per worker, content-hash incremental skip so re-ingesting unchanged text is free, and configurable ingestion profiles (`conservative`/`balanced`/`aggressive`/`max`). LLM grounding, the sidecar's full feature parity, and the cross-implementation parity harness are still landing in subsequent plans.

## Why a Rust line at all?

- **The hot path is mechanical, not magical.** Most of pg-raggraph's cost is ingest plumbing and connection/transaction overhead — exactly what Rust plus a single in-database extension removes. A transaction-scoping fix alone took the bake-off ingest from 14 minutes to 119 seconds.
- **`pgrx` keeps the bet honest.** The architectural premise behind pg-raggraph is "don't add a second system." A Rust Postgres extension is the strongest version of that: the graph and vector work runs where the data already lives.
- **Managed Postgres gets a path too.** Cloud-managed Postgres (RDS, Cloud SQL, Supabase, Neon) forbids `shared_preload_libraries`, so the extension can't load there at all. The `pg_raggraph_sidecar` binary runs the same core engine as an external process over plain libpq + HTTP — no pgrx, no SPI, no preload — for exactly that case.

## Cross-implementation parity

A `bench/parity/` harness checks that this Rust extension and the Python `pg-raggraph` library return equivalent retrieval results — top-k Jaccard ≥ 0.8 is the machine-decidable bar, enforced in CI at increasing scale from PR to tag.

## Links

- [GitHub Repository](https://github.com/yonk-labs/pg-raggraph-rs)
- Reference implementation: [pg-raggraph](https://github.com/yonk-labs/pg-raggraph) (Python)
- Shared dependency: [chunkshop](https://github.com/yonk-labs/chunkshop) (chunking + embedding pipeline)
- License: Apache 2.0
