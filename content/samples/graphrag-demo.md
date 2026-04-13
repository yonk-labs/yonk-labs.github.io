---
title: "GraphRAG Demo: Apache AGE + pgvector on Postgres 16"
date: 2026-04-14
draft: false
tags: ["postgres", "rag", "graphrag", "pgvector", "apache-age", "docker", "python"]
summary: "Runnable sample app: Postgres 16 with Apache AGE and pgvector, a FastAPI orchestrator, and four retrieval strategies compared side by side on 391 real SCOTUS cases."
---

Companion code for the GraphRAG on Postgres blog series. One Postgres instance. One `docker compose up`. Four retrieval strategies (vector, hybrid, graph, combined) running in parallel against 391 real SCOTUS cases, rendered side by side so you can see exactly where each approach wins and loses.

**Repo:** [github.com/yonk-labs/graphrag-demo](https://github.com/yonk-labs/graphrag-demo)

## What it demonstrates

- Postgres 16 with `pgvector` (HNSW index) and `apache_age` (Cypher traversals) built from source in one image — no second datastore
- FastAPI orchestrator that runs four retrieval strategies in parallel and returns stage-by-stage timings
- Multi-hop query detection via substring matching + a dispatch table (deliberately minimum-viable, swap in an LLM when you want)
- Pluggable LLM providers (Claude, OpenAI, Ollama) and pluggable embedding providers (local sentence-transformers, OpenAI)
- A comparison UI with four columns so you can actually *see* which retriever wins on which question
- 391 real Supreme Court cases (2018–2023) shipped inside the Docker image — no external data dependencies, no API keys required to seed

## Quick start

```bash
git clone https://github.com/yonk-labs/graphrag-demo.git
cd graphrag-demo
cp .env.example .env
# edit .env — add ANTHROPIC_API_KEY or OPENAI_API_KEY

docker compose up --build
# open http://localhost:8000
```

First build takes ~5 minutes (compiling the Postgres extensions). After that, near-instant.

## Stack

| Piece | Choice |
|---|---|
| Database | Postgres 16 |
| Vector search | pgvector 0.8.0, HNSW index |
| Graph | Apache AGE 1.5.0, Cypher via `cypher('graph_name', $$ ... $$)` |
| API | FastAPI + psycopg |
| Embeddings | sentence-transformers `all-MiniLM-L6-v2` (local, 384-dim) by default |
| LLM | Claude / OpenAI / Ollama, swappable via `.env` |
| Dataset | 391 real SCOTUS cases, 2018–2023 terms |

## Blog series walkthrough

1. [Vector+BM25 Is the Floor. Graph Is the Multiplier.](../../blog/graphrag-part1-vector-vs-graph/) — the three question shapes, honest benchmarks, the 3-stage architecture
2. [Getting Apache AGE and pgvector Running on Postgres 16](../../blog/graphrag-part2-postgres-age-pgvector/) — the full Dockerfile, init SQL, your first vector query, your first Cypher query
3. [Building the GraphRAG Demo: 391 SCOTUS Cases, Four Retrieval Strategies](../../blog/graphrag-part3-scotus-showdown/) — the schema, the strategies, multi-hop query detection, real query results, and what a production architecture should actually look like

## Project layout

```
graphrag-demo/
├── docker-compose.yml          # Postgres + App
├── postgres/
│   ├── Dockerfile              # PG16 + AGE + pgvector from source
│   └── initdb/                 # Init SQL (extensions, schema, graph labels)
├── app/
│   ├── main.py                 # FastAPI orchestrator
│   ├── retrieval/              # vector / hybrid / graph / combined
│   ├── embeddings/             # Pluggable embedding providers
│   ├── llm/                    # Pluggable LLM providers
│   ├── seed/                   # SCOTUS parser + loader
│   └── static/                 # Demo UI
└── blog/                       # Tutorial drafts (also published here)
```

## License

Apache-2.0. Fork it, break it, ship something better.
