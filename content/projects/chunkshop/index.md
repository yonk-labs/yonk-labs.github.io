---
title: "chunkshop"
date: 2026-04-19
draft: false
tags: ["python", "rust", "rag", "pgvector", "chunking", "embeddings", "fastembed", "onnx"]
summary: "Standalone ingest-to-pgvector with a built-in chunker × embedder bakeoff. One YAML config = one end-to-end ingest cell. Python + Rust at parity."
externalUrl: "https://github.com/yonk-labs/chunkshop"
---

**chunkshop** is a small, standalone, embeddable ingestion tool for RAG pipelines. Pulls text from a source, chunks it, embeds it, optionally tags it, and lands the result in a pgvector table. One YAML config = one end-to-end ingest "cell." The headline feature is the **bakeoff** — run every (chunker × embedder) combo against your corpus and gold set, get a leaderboard, get a `recommended.yaml`, ship it.

## Why chunkshop?

- **Pick the right recipe for *your* data** — bakeoff is step 1 of every adoption, not a sample. Bring your corpus + ~10 gold queries, run the matrix, ship the winner.
- **Swap any box without touching the others** — source · framer · chunker · embedder · extractor · target are clean boundaries with multiple implementations each.
- **One config schema, two languages** — Python and Rust share the same YAML, the same ONNX embedder, and the same target table layout. Single-cell vectors are interchangeable.
- **Library *or* CLI** — drive it from your host app via `Pipeline`, or run `chunkshop ingest --config cell.yaml` from the shell.
- **Parallel multi-cell ingest** — `chunkshop orchestrate` fans multiple YAMLs out as parallel subprocesses (Python).
- **MIT licensed** — drop it into anything.

## What it's for

- **RAG retrieval pipelines** — chunk, embed, land in pgvector with HNSW. Filter by source tag, by metadata, by tags array.
- **Multi-source ingest into one table** — different YAMLs for different sources, same target, schema-flex modes for evolving corpora.
- **Tuning per corpus** — the leaderboard tells you which chunker/embedder pair wins on *your* documents instead of guessing from someone else's benchmark.
- **Prototype-to-prod** — start with the canonical NTSB bakeoff, swap in your data, take the recommended cell to production.

## Pipeline

```
Source → Framer → Chunker → Embedder → Extractor → pgvector + HNSW
```

Each arrow is a boundary. Chunkers include `sentence_aware`, `fixed_overlap`, `hierarchy` (heading-prefixed, benchmark winner on legal QA), `neighbor_expand`, `semantic`, `summary_embed`, and `hierarchical_summary`. Embedder default is `Xenova/bge-base-en-v1.5-int8` (~85 MB, CPU-fast, MTEB-backed). Extractors cover keywords, key phrases, spaCy entities, language detection, and composites.

## Tech Stack

- **Languages:** Python (reference impl, on PyPI) and Rust (on crates.io)
- **Embedder runtime:** ONNX via `fastembed` (Python) and `ort` (Rust)
- **Target:** PostgreSQL with `pgvector`, HNSW index
- **Parity:** single-cell pipeline + bakeoff are bit-near-equivalent across Python and Rust; orchestrator is Python-only

## Quick Start

```bash
# 1. Install
pip install chunkshop

# 2. Point at your Postgres (pgvector required)
export CHUNKSHOP_DSN="postgresql://postgres:postgres@localhost:5432/mydb"

# 3. Run the canonical bakeoff against the NTSB aviation-accident corpus
chunkshop bakeoff --config docs/samples/bakeoff-ntsb/bakeoff-ntsb.yaml \
                  --dsn "$CHUNKSHOP_DSN" --yes

# 4. Take the recommended cell to production
chunkshop ingest --config skill-output/bakeoff/ntsb_bakeoff/recommended.yaml
```

## Links

- [GitHub Repository](https://github.com/yonk-labs/chunkshop)
- [PyPI: chunkshop](https://pypi.org/project/chunkshop/)
- [crates.io: chunkshop-rs](https://crates.io/crates/chunkshop-rs)
- License: MIT
