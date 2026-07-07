---
title: "graphrag-demo"
date: 2026-07-01
draft: false
tags: ["python", "postgresql", "apache-age", "pgvector", "graphrag", "rag"]
summary: "Apache AGE + pgvector in one PostgreSQL instance, side by side. Ask a question, watch vector-only, graph-only, and graph+vector retrieval run in parallel with timing for each."
externalUrl: "https://github.com/yonk-labs/graphrag-demo"
---

**graphrag-demo** is a sample app showing what graph-augmented retrieval actually buys you over plain vector search — by running both, plus the combination, against the same question at the same time and showing the timing breakdown for each.

## What it demonstrates

Every query runs three retrieval strategies in parallel: vector-only (embed the question, cosine similarity via pgvector), graph-only (extract entities, traverse relationships via Apache AGE's Cypher support), and graph+vector (vector search seeds the traversal, graph expansion pulls in related context, and a re-ranking step combines both signals). Seeing all three answer the same question side by side makes the tradeoff concrete instead of theoretical — vector search is good at semantic similarity, graph traversal is good at structural connections neither approach alone would surface.

## Stack

PostgreSQL 16 with `pgvector` (HNSW index) and `apache_age` (Cypher graph queries) in one instance, a FastAPI orchestrator running the three strategies concurrently, and pluggable LLM (Claude, OpenAI, Ollama) and embedding providers.

## Quick start

```bash
cp .env.example .env
# set ANTHROPIC_API_KEY or OPENAI_API_KEY in .env

docker compose up --build
# open http://localhost:8000
```

The database seeds itself on first run with roughly 160 documents about a fictional organization, so there's a working corpus to query immediately.

## Blog series

The repo accompanies a three-part write-up: why vector search alone falls short, building the graph-aware pipeline, and the head-to-head comparison — all included in the `blog/` directory.

## Links

- [GitHub Repository](https://github.com/yonk-labs/graphrag-demo)
- Related: [pg-raggraph](https://github.com/yonk-labs/pg-raggraph) (the production-grade version of this idea, without Apache AGE)
- License: Apache 2.0
