---
title: "The weird stuff: chunkshop's deeper features and what's coming next"
date: 2026-05-13
draft: false
tags: ["chunkshop", "rag", "postgres", "pgvector", "chunking", "embeddings", "ingest", "roadmap"]
summary: "The features I'd argue are genuinely novel — framers, hierarchical summaries, BYO embedders via four lines of YAML, schema-flex append mode, cross-language vector compatibility, and the modular-backends roadmap toward MariaDB and ClickHouse. Plus the four bets chunkshop is making about where RAG infrastructure goes next."
build:
  list: never
---

Three posts in, you have the basics. Bakeoff before you commit. Hybrid search beats pure vector search. Inline mode keeps reads and writes in the same vector space.

This post is the part where I tell you what I think is genuinely novel about chunkshop — the features that aren't in any other ingest library I've looked at, the features I'd argue are pointing toward where this whole space is going. Some of these are shipped. Some are work-in-progress on a long-running experimental branch. All of them are things I'd want a serious RAG engineer to know about before picking a stack for the next two years.

Strap in.

## 1. The framer stage — re-slicing the source before chunking

Most ingest libraries treat one source row as one document. That's the wrong assumption about half the time. The other half of the time you're either dealing with a giant concatenated dump (someone exported their wiki to a single markdown file) or a JSON envelope where the real items are nested under some key you don't control.

Chunkshop's framer stage sits *between* the source and the chunker. It takes one raw source `Document` and yields N framed `Document`s. The chunker, embedder, extractor, and target all see only the framed docs.

Three framers ship by default:

- `identity` — the no-op. One source row in, one document out. The default for every existing cell.
- `heading_boundary` — splits a single markdown blob on a configurable heading level. The "I exported my wiki to one file" pattern.
- `regex_boundary` — splits on an arbitrary regex. The "I have a log file with custom record separators" pattern.
- `jsonpath` — picks items out of a JSON document by JSONPath. The "the API returns `{items: [...]}` instead of an array" pattern.

The use case I want you to internalize is the heading-boundary one. You have a 50,000-word handbook in one markdown file. The natural unit isn't the file — it's each `##` section. Without a framer, your chunker sees one giant document and either produces one massive chunk (`hierarchy` collapsing to root) or produces a flood of fine chunks with no logical doc-id grouping. With `heading_boundary` framing on `##`, each `##` section becomes its own document, gets its own `doc_id`, and downstream operations (delete, re-ingest, filter) operate at the section level instead of the file level.

That last point is what makes framers more than syntactic sugar. In an incremental ingest world, **the doc_id is the unit of update**. If your `doc_id` is the wrong granularity, every other freshness pattern breaks. Framers fix the granularity at the read seam.

## 2. Hierarchical summaries — match coarse, return fine

I covered `hierarchical_summary` briefly in the chunkers post; this is the deeper version because it's the chunker I think is most genuinely novel.

The retrieval problem with long documents is well-known. A 5,000-word section embedded as one chunk has a vector that's the average of everything in that section, including the boring procedural sentences that dilute the signal. If your query is "what does the policy say about X," and X is mentioned in three sentences buried in 5,000 words, the vector for that section barely moves toward X. You miss the document. Or you split the section into 300-word chunks, and now you've got fifteen chunks whose individual vectors are precise, but you've lost the section-level context that would have helped the retriever orient.

Hierarchical summary punches through this by emitting both layers in the same vector table. Each section produces:

- One **coarse** row per group: `granularity: coarse`, `embedded_content` is a summary of the whole group, `original_content` is the summary text.
- N **fine** rows per group: `granularity: fine`, normal chunks from your base chunker, linked by `metadata.group_id`.

At query time you do a two-stage retrieval. Step one: query with `WHERE granularity = 'coarse'`, find the top-K group_ids. Step two: query with `WHERE granularity = 'fine' AND group_id IN (...)`, get the actual answer chunks. Or, alternatively, weight the two layers in a single ranked retrieval — coarse summaries pull the right neighborhood, fine chunks rank within it.

Both layers share the `embedding` column dimension and the `(doc_id, seq_num)` primary key — they live in one table, queried with one connection. There's no separate "summary store" to maintain.

The summary itself can come from three places:

- **External** — a column on the source row already contains a summary. Your CMS has an `abstract` field; wire that column as the summary source. Zero compute, zero LLM.
- **Callable** — point chunkshop at a Python module and entry point that takes text and returns text. The recommended pairing is the `lede` library (extractive summarization, zero dependencies, ~1ms per chunk). You can wire any LLM-based summarizer the same way.
- **Passthrough** — the chunk text *is* the summary. Useful as a baseline; rarely the right answer in production.

The thing I want you to take away: separating "what gets embedded" from "what gets stored" is one of the highest-impact choices in this space, and almost no ingest library lets you make it cleanly. Chunkshop does.

## 3. BYO embedders — four lines of YAML, no rebuild

You saw the BYO pattern in the tutorial. Let me go a step further on why this matters.

The default chunkshop registry has bge-small, bge-base, MiniLM, and a couple of nomic variants. That's it. Six months ago, if you wanted to swap in a different embedder — Snowflake Arctic, Cohere's open weights, JinaAI's v3, whatever the model-of-the-week is — you had to edit Python source files, edit Rust source files, run `uv sync`, run `cargo build`, and reinstall. The model registry was code, not data.

The BYO pattern moved the registry from code to YAML. Four lines:

```yaml
embedder:
  type: fastembed
  model_name: my-byo-label
  dim: 1024
  hf_repo: org/repo-name
  onnx_path: onnx/model.onnx     # path inside the HF repo
  pooling: cls                   # "cls" or "mean"
```

Both Python and Rust implementations honor the same YAML. Both fetch the model from HuggingFace at config-load time, both cache it in the standard fastembed cache directory, both fail with the same "verify the file exists at https://..." error message if the path is wrong.

The deeper consequence is that the *bakeoff* matrix can include arbitrary external models without anyone editing chunkshop source code. Your bakeoff config is data. You can have ten production cells in your codebase, each with a different embedder, none of them in the chunkshop registry, all of them just YAML. Adding the next model-of-the-week is a YAML edit, not a release cycle.

`dim` is a contract. If your YAML claims dim 768 and the model produces 384, both implementations error before writing anything to pgvector. No silent corruption. No "we ingested ten million rows with the wrong embedder, please reschedule the demo."

## 4. Schema-flex append mode — multiple cells, one target table

Chunkshop's default sink mode is `overwrite` — DROP TABLE, CREATE TABLE, populate. Fine for a single-source pipeline. Useless when you want multiple cells writing into the same logical store with provenance.

The append mode fixes that. Set `target.mode: append`, supply a `source_tag`, and chunkshop runs a strict pre-flight: the table must exist, the embedding dim must match, the `source` column must be present, and the `promote_metadata` columns are added with `ADD COLUMN IF NOT EXISTS` if they're not already there. If anything mismatches, the cell refuses to start.

The provenance contract: every chunk row carries a `source` column equal to the cell's `source_tag`. The write path's UPSERT explicitly excludes `source` from the UPDATE clause. So if Cell A and Cell B collide on the same `(doc_id, seq_num)` — same identifier, two different sources — the first writer's tag wins forever. This is by design. It means your retrieval queries can `WHERE source IN ('crm_notes', 'support_tickets')` and you know exactly which cell produced each row.

Why this matters at the system level: most production RAG isn't single-source. You have customer notes from the CRM, support tickets from Zendesk, marketing pages from the CMS, and documentation from the wiki. Each has a different chunker preference, a different embedder, a different update cadence. With `append` mode, each gets its own cell, all of them write into the same target table, and your retriever queries one place with provenance baked in.

I have not seen another ingest library handle this cleanly. Most either force you into one global pipeline (which can't accommodate the per-source chunker differences) or force you into N separate tables (which forces query-time UNION joinery). Chunkshop's append mode is the middle path: N pipelines, one table, clean provenance.

## 5. Cross-language vector compatibility (Python ↔ Rust ↔ Go)

The Python implementation is the reference. The Rust port is shipping incrementally — schema-flex mode is in, the BYO YAML pattern is in, semantic chunker has Rust drift ~1e-3 cos. Go is on the roadmap.

The deliberate, load-bearing constraint across all three: **vectors produced by any implementation are byte-compatible with vectors produced by any other.** Same int8 model variants. Same `(doc_id, seq_num)` schema. Same chunker output for structural chunkers (semantic chunker has small drift due to ONNX runtime numerical differences). Same target table layout.

Why this is the load-bearing constraint: real production systems don't get to pick one language. You have a Python data pipeline running overnight batch ingest. You have a Rust service mesh handling real-time webhooks. You have a Go ingestion worker draining a Kafka topic. All three need to write into the same vector store, and the vectors better be in the same space, or your retrieval is silently broken.

Most multi-language toolchains punt on this. They define one canonical implementation, declare the others "experimental," and let the implementations drift. Chunkshop's structural chunkers are byte-identical across Python and Rust by deliberate test discipline — there's a parity test suite that runs the same fixture through both implementations and asserts identical output. The semantic chunker has documented drift bounds; everyone else is exact.

The practical consequence is that you can run the bakeoff in Python (where the toolchain is faster to iterate) and ship the picked config to a Rust service for production ingest. The Rust service produces the same vectors the Python bakeoff scored. There is no "well, Python's `hierarchy` and Rust's `hierarchy` are *roughly* the same" weasel-clause.

## 6. Modular backends — Postgres today, MariaDB and ClickHouse next

The next big architectural shift is on a long-running experimental branch. The current implementation hardcodes Postgres + pgvector as the only target. A v4.0 design spec — drafted in late April 2026 and currently in the writing-plans phase — generalizes the storage layer so the same YAML can target Postgres, MariaDB (with their newly-shipped vector type), or ClickHouse, on both the source side and the sink side.

The design highlights I think are interesting:

**Symmetric backends.** Source and sink both consume a `Backend` abstraction. Cross-backend pipelines — read source rows from MariaDB, write vectors to Postgres — are first-class flows. This is the case for analytics shops where the OLTP system isn't where you want to run vector search.

**Loose schema parity.** The logical model (chunk, embedding, metadata, source_tag) is shared. The physical types are native per backend — Postgres uses `vector`, MariaDB uses `VECTOR(dim)`, ClickHouse uses `Array(Float32)` with USearch indexes. Chunkshop doesn't try to abstract over the type system; it abstracts over the chunkshop-level operations and lets each backend speak its own DDL.

**Re-ingest, not migration.** v4 will deliberately break the v0.3.x Postgres schema for cleanliness. There is no upgrade script. The migration policy is "re-run the cell." This is the right tradeoff for a tool whose purpose is making re-ingest cheap.

**ClickHouse-as-sink semantics.** Append-only. `delete_orphans` is a no-op (warns). Provenance via natural append plus `argMax(created_at)` reader pattern, or `ReplacingMergeTree`. Different from Postgres in ways that match the engine; same `chunkshop` interface from the user's side.

First ship is PG-refactor + MariaDB. ClickHouse is design-supported but built later. v4.0 lives on `experimental/v4-modular-backends`; no hard release commitment yet.

The reason this matters even if you're a Postgres shop: the abstraction work flushes out the Postgres-specific assumptions in the current code. Once `Backend` is a real interface, the per-backend `Sink` implementations are smaller, cleaner, and easier to extend. The Postgres implementation gets *better* by being one of three siblings instead of the entire universe.

## 7. The composability story

The thing I haven't said directly yet: every layer of chunkshop is a Python `Protocol` with one method. Sources have `iter_documents()`. Framers have `frame()`. Chunkers have `chunk()`. Embedders have `embed()`. Extractors have `extract()`. Sinks have `write_document()`.

Adding a new source / framer / chunker / embedder / extractor is one new file plus one branch in the loader. No base class. No registration decorator. No metaclass magic. Drop the file, wire the loader, write a test. The hard part is not the integration — it's *what your new component does*.

This sounds boring until you remember most ingest libraries are not like this. They have inheritance hierarchies, plugin registries, dependency injection containers, and configuration ceremonies that take a week to navigate before you can ship a one-file extension. Chunkshop is deliberately allergic to that.

The flip side: if your problem is genuinely complex — a custom protocol-buffer source, an LLM-based extractor that needs careful caching, a sink that writes to two backends transactionally — chunkshop gives you the bare bones and gets out of your way. There's no opinionated framework forcing you into its abstraction. There's a Protocol with one method, and you decide what's behind it.

## What I think this points toward

If you squint, chunkshop is making a few bets about where RAG infrastructure is going.

The first bet: **the data engineering layer is where the actual gains are**, and that layer is currently underserved by tooling. Everyone is building on top of LangChain and LlamaIndex. Almost nobody is building the boring pieces underneath. Bakeoff, framers, hierarchical summaries, schema-flex append, BYO YAML — these are all "boring" infrastructure that should be in every RAG stack and isn't.

The second bet: **YAML-as-contract beats code-as-config**. The reason chunkshop's YAML is strict (pydantic with `extra="forbid"`) is the same reason your typed-language compiler catches typos: a typo in a config file should error at load time, not silently change behavior at runtime. The YAML is the contract between you, your team, and the next person who maintains this pipeline.

The third bet: **multi-backend, multi-language, multi-source is the production reality**, not the special case. Single-tool, single-language, single-source pipelines are demo-ware. Real production has overnight Python batch jobs, real-time Rust webhooks, three sources of truth, and two destinations. The infrastructure should match.

The fourth bet — and this is the one I'd defend with a podium — **measurement beats intuition**. Pick chunkers by data, not by reputation. Pick embedders by data, not by hype. The bakeoff isn't a feature; it's the *thesis*. Every other feature in chunkshop exists in service of making bakeoff cheap enough to run before every meaningful decision.

## What's next on the roadmap

The honest near-term list, in roughly the order it's likely to ship:

- Modular backends. PG-refactor + MariaDB sink, then MariaDB source, then ClickHouse. Probably v4.0.
- Async I/O. Currently sync everywhere; async is on the roadmap once the modular-backends work settles.
- Rust feature parity with Python. The structural chunkers and BYO are there; semantic chunker, summary-layer chunkers, and bakeoff are next.
- Go port. Has been on the roadmap since before chunkshop got named at 5:47 AM. Will land when the abstractions settle.

Things I am not promising and you should not assume:

- A managed cloud version. Chunkshop is a tool, not a service. Run it where your data is.
- Built-in LLM extraction. Out of scope. Wire your own as an extractor.
- Vector store agnosticism beyond the modular-backends list. Pinecone / Weaviate / Qdrant are not on the roadmap. The whole point of chunkshop is to lean into the database you already have.

That's the survey. Four posts in, you've now seen the whole thing — the chop-shop origin story, the end-to-end tutorial on a real OLTP corpus, the chunker field guide, and this deep dive into the unusual features.

If any of this lands for you, the GitHub repo is [yonk-labs/chunkshop](https://github.com/yonk-labs/chunkshop). Issues welcome. Pull requests warmly received. The bakeoff configs from these posts are committed in `docs/samples/`. Drop them at your data, see what your numbers look like, and tell me what you find. I am especially interested in corpora where the chunker leaderboard surprises me, because those are the ones that teach me something I didn't already know.

Pull up. We'll chunk it for you.
