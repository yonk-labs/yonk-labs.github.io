---
title: "pg-raggraph-rs"
date: 2026-05-11
draft: false
tags: ["rust", "postgresql", "pgrx", "graphrag", "performance", "rag"]
summary: "The Rust performance line for pg-raggraph — pushing GraphRAG-in-Postgres toward an in-database pgrx extension and a tighter ingest/retrieval hot path."
externalUrl: "https://github.com/yonk-labs/pg-raggraph-rs"
---

**pg-raggraph-rs** is the Rust line of [pg-raggraph](https://github.com/yonk-labs/pg-raggraph) — the same GraphRAG-in-PostgreSQL model, taken down the performance road. The goal is to keep the storage and retrieval hot path tight and to move work *into* the database via a `pgrx` extension instead of round-tripping it from a client.

## Why a Rust line?

- **The hot path is mechanical, not magical** — most of pg-raggraph's cost is ingest plumbing and connection/transaction overhead, exactly the kind of thing Rust + a single in-database extension removes. A single transaction-scoping fix already took the bake-off ingest from 14 minutes to 119 seconds (7×), landing within the ≤3× Apache AGE target.
- **`pgrx` keeps it in one database** — the architectural bet behind pg-raggraph is "don't add a second system." A Rust Postgres extension is the strongest version of that bet: the graph and vector work runs where the data already is.
- **Parity with the Python reference** — pg-raggraph's Python implementation stays the readable reference; the Rust line targets the same schema and semantics with a faster engine underneath.

## Where it's headed

The three architectural directions on the table: a `pg_net` sidecar for embedding calls, a `pgrx` Rust extension for the in-database path, and hybrid embedding tiers. This repo is where the Rust/pgrx work lands.

## Links

- [GitHub Repository](https://github.com/yonk-labs/pg-raggraph-rs)
- Reference implementation: [pg-raggraph](https://github.com/yonk-labs/pg-raggraph) (Python)
