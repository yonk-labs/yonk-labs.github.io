---
title: "pg-raggraph"
date: 2026-05-05
draft: false
tags: ["python", "postgresql", "graphrag", "pgvector", "rag", "ai", "recursive-cte"]
summary: "GraphRAG that runs entirely in PostgreSQL — pgvector for vectors, recursive CTEs for graph traversal, tsvector BM25 for keyword search. No graph database, no second backup strategy, no data sync."
externalUrl: "https://github.com/yonk-labs/pg-raggraph"
---

**pg-raggraph** is a GraphRAG library that runs entirely in PostgreSQL. pgvector handles the vector side, adjacency tables and recursive CTEs handle the graph side, and `tsvector` provides BM25 keyword search — all in one ACID-compliant database. No graph extension, no second system to back up, no data sync between two stores.

## Why pg-raggraph?

- **Most GraphRAG workloads don't need a graph database** — vector similarity, 1-3 hop traversal, and a result merge are the entire hot path. Recursive CTEs over an adjacency table do the traversal in 30-100ms, which is the hop budget GraphRAG actually uses.
- **One database, one backup story** — if your data already lives in Postgres, `pip install pg-raggraph` and start ingesting against the same instance your application talks to. No ETL out and back.
- **Deploys where you actually run** — works on a stock managed Postgres (e.g. AWS RDS). No need for a graph extension that your cloud provider doesn't offer.
- **Honest about where it loses** — benchmarked across six corpora (Postgres docs, NTSB reports, sales call notes, MuSiQue multi-hop QA, versioned Python docs, PubMed abstracts), with the cases where graph augmentation *doesn't* pay off documented rather than hidden.

## What it's for

- **GraphRAG retrieval** — entity/relationship extraction plus graph-augmented retrieval for multi-document reasoning, without standing up Neo4j or Apache AGE.
- **Agent memory** — the relational/episodic, time-anchored kind of memory that needs a graph traversal, not just a vector match.
- **Multi-hop QA** — walk from a query's seed entities to related documents that share entities, in one SQL query plan.

## Architecture

```
Documents → Chunks → Entities → Relationships  (+ provenance junction tables)
            pgvector (HNSW)   recursive CTEs   tsvector BM25 + pg_trgm (GIN)
```

Six tables — documents, chunks, entities, relationships, plus `entity_chunks` and `relationship_chunks` provenance links back to source. Indexes: HNSW for vectors, GIN for tsvector + fuzzy matching, btree for adjacency joins.

## Links

- [GitHub Repository](https://github.com/yonk-labs/pg-raggraph)
- Related: [pg-raggraph-rs](https://github.com/yonk-labs/pg-raggraph-rs) (Rust / pgrx performance line)
