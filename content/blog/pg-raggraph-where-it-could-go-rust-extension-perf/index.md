---
title: "I made pg-raggraph 7× faster by deleting code I wrote. Here's where it goes next."
date: 2026-05-11
draft: false
tags: ["pg-raggraph", "postgres", "performance", "rust", "pgrx", "benchmarking", "rag"]
summary: "A 17× perf gap between pg-raggraph and Apache AGE turned out to be 5 lines of glue code in the bakeoff adapter, not an architectural problem. The fix, the four library-side wins still on the floor, and the three architectural directions ahead — pg_net sidecar, pgrx Rust extension, hybrid embedding tiers."
build:
  list: never
---

There's a category of bug that's particularly painful — the one where you publish a benchmark, somebody points out the number looks wrong, and the wrongness turns out to be in code *you* wrote, not in the system you were measuring. I had one of those a few weeks ago.

The setup: pg-raggraph's bake-off against Apache AGE on the SCOTUS legal-QA corpus. Pre-extracted entities and relationships from the same JSON cache, fed into both engines, both writing to their own schemas. AGE finished in 50 seconds. pg-raggraph took 14 minutes.

That's a 17× gap on the storage-only path. I had to either explain it or fix it. (Both, actually. My version of explaining it was "I was an idiot.") The whole thing is a microcosm of where pg-raggraph is performance-wise and where it's going next, so let's walk through it.

## How a 14-minute storage step happens

The bake-off adapter — the glue layer that bridges pg-raggraph's library and the bake-off harness — was making one transactional round-trip per row. Per row. For 772 documents, 4,397 relationships, plus all the chunk-entity provenance link rows, that's roughly 10K-50K individual `db.execute` calls, and each one was acquiring a fresh pool connection, calling `register_vector_async` (which itself fires a SELECT against `pg_type` to discover the vector codec), running one statement, committing, and releasing the connection.

Round-trip latency on localhost is about 1-3 milliseconds even when nothing is contended. Multiply by 30K calls and you have your 14 minutes. The library's actual ingest path doesn't have this bug — `_ingest_one_file` correctly wraps everything in one `db.transaction()` per document — but the *adapter* I wrote for the bake-off had reverted to a per-row connection pattern. Probably because I copied an early prototype and never went back.

The fix took 5 lines of structural change. Wrap the entire ingest in `async with db.transaction() as tx`. Replace `db.execute` calls with `tx.execute`. One connection across the whole ingest. One COMMIT at the end. The vector codec gets registered exactly once instead of per-row.

Result: 14 minutes → 119 seconds. 7× speedup. From a single-line refactor.

I added a second optimization (F2): pre-build the entity_chunks and relationship_chunks linkage rows in Python via an inverted index, then `executemany` them in batches instead of looping per (chunk, entity) match. Another 12 seconds off, dropping us to 107 seconds — 2.1× the AGE baseline of 50 seconds, well within the "≤3× AGE" target I'd set as the public-flip gate.

The lesson isn't "I'm a bad engineer" (although yes, sometimes). The lesson is that a 17× gap published to a benchmark looked like a fundamental architectural problem and was actually 5 lines of glue code. Always double-check the layer that's not under test before you blame the layer that is.

## What's left on the floor

The perf-audit subagent that found the connection-pool bug also catalogued four real library-side improvements (I'll call them F3 through F6). None of them are blocking, none are urgent, but they each have a specific shape worth talking through because they show where pg-raggraph's perf model goes next.

**F3: combine entity-resolution round-trips.** The resolution path (pg_trgm fuzzy + vector cosine for entity dedup) currently does up to 3 round-trips per entity — exact-name SELECT, fuzzy SELECT, then UPDATE-or-INSERT. Each round-trip is ~1ms on localhost. On a corpus with 10K extracted entities and even modest dedup overlap, that's 30 seconds of round-trip time *just* in resolution. The fix is a single CTE that combines exact + fuzzy lookup into one query and an UPSERT. Maybe 2-3× speedup on the resolution-bound portion of ingest. Pure refactor, no behavioral change.

**F4: register the vector codec once per pool connection, not per call.** This is the thing the bake-off adapter was hitting via the `register_vector_async` call inside every `db.execute`. Even after F1+F2 closed the bake-off bug, the library's *general* code paths still re-register on every call. The right shape is to use the connection pool's `configure` callback so each connection gets the codec once at creation. ~10 lines, helps every short-query workload (status checks, retrieval, the bake-off adapter pre-F1, all of it).

**F5: optional bulk-load mode that drops and recreates HNSW indexes around large initial ingests.** pgvector's own docs say HNSW indexes build significantly faster after the data is loaded than incrementally during. For one-shot bulk loads of >100K chunks, drop the HNSW index, ingest, recreate the index with `CREATE INDEX CONCURRENTLY` and a bumped `maintenance_work_mem`. The cost is that the index is gone during ingest (concurrent reads do seq scans). The win is significant on bulk loads. This stays opt-in — `bulk_load=True` flag — because incremental online ingest needs the index up.

**F6: opt-in `synchronous_commit=off` for ingest sessions.** Standard "I'm willing to lose the last few seconds of writes on a crash" tradeoff. Each commit currently waits for WAL fsync (~0.5-2ms on a typical SSD). Per-document commits on a 1000-doc ingest is 0.5-2 seconds of fsync stalls; pre-F1 with per-row commits it was 5-20 seconds. Document the crash window loudly. Default off. Worth maybe another 1.1-1.3× on storage time after F1+F2 are applied.

These aren't dramatic individually. They compound. F3 + F4 alone probably take a 100-doc ingest from ~2 minutes to ~1 minute on the library path. None of them require touching the data layer.

## The bigger architectural question

Where does pg-raggraph go from here, really? Three directions worth taking seriously, in increasing order of ambition.

### Direction one: SQL-callable primitives via pg_net + a sidecar

This is the pragmatic next step. pg-raggraph today is a Python library — you import it, you call `rag.ingest_records(...)` from Python. That's fine for batch ingest from a Python ETL job. It's awkward when the ingest needs to fire from a Postgres trigger, a `pg_cron` job, or a stored procedure.

The shape that fits is a small HTTP sidecar that exposes `embed(text)` and `extract(chunk_text)` — literally the existing pg-raggraph Python code, just bound to a port. SQL functions in postgres call it via `pg_net` (which is async by default and widely available across managed providers). The chunking, entity resolution, and graph storage stay pure SQL. The end-state surface looks like:

```sql
SELECT pgrg.ingest_record(
    text       => sn.note_text,
    source_id  => 'sales_note:' || sn.note_id,
    namespace  => 'sales_calls',
    metadata   => jsonb_build_object('order_id', sn.order_id)
)
FROM sales_demo_app.sales_notes sn
WHERE sn.status = 'won';
```

One SQL primitive. Composes with triggers, materialized views, scheduled jobs. The sidecar is the same Python library bound to a different transport. The Python API stays as-is for users who want it.

This is a 3-6 month effort done right (HTTP service definition, error handling, batching, retries, the SQL function wrappers). Not blocking on anything. Not currently committed. Captured in `docs/proposals/DB-Native-Ingest.md` as Path A.

### Direction two: the Rust extension

The aspirational version. A `pg_raggraph` extension built via [pgrx](https://github.com/pgcentralfoundation/pgrx), packaged as a real postgres extension. `CREATE EXTENSION pg_raggraph` and you have everything — the embedder, the LLM client, the chunker, the entity resolver, the graph storage, the retrieval modes — natively in postgres.

The advantages would be real. Native types, native transactions, native function dispatch. No sidecar to operate. Embeddings inside the database process (with all the operational implications of that). HNSW + adjacency joins in one execution plan, no marshalling.

The blockers are also real, and they're the same blockers that made me say no to depending on Apache AGE in the first place. Most managed postgres providers don't allow custom extensions without explicit allowlisting. AWS RDS, GCP Cloud SQL, Supabase, Neon — every one of them has a curated extension list and getting onto that list is a 6-12 month process at best. If pg-raggraph ships as a Rust extension, we close off the deployment story for everybody who isn't running self-hosted postgres or Azure Database for PostgreSQL.

So this stays a long-term aspiration. Three things would have to be true before I'd start serious engineering on it: cloud providers ship a third-party extension story (Supabase has hinted at this; nothing concrete), there's enough demand from the self-hosted segment to justify the work, and the existing Python library has stopped being adequate for some specific workload that *only* a native extension can handle. None of those is true today.

### Direction three: hybrid embedding architecture

This is the speculative one. The current architecture assumes embeddings are computed at ingest time and stored as `vector(N)` columns. Retrieval does cosine similarity. Standard pgvector pattern.

What if you don't have to commit to a single embedder dim at ingest? Two emerging patterns make this less hypothetical than it sounds.

First, [Matryoshka embeddings](https://huggingface.co/blog/matryoshka). Models trained so that the first 256 dims are usable, the first 512 dims are better, the full 768 are best. You store the full embedding once and query at whichever dim fits the latency budget. Postgres supports this today via `embedding[1:256]::vector(256)` slicing — no schema change needed.

Second, [iterative re-ranking with a stronger but slower embedder](https://research.google/pubs/iterative-rephrasing-for-retrieval/). Vector retrieval with a cheap embedder pulls top-100, a stronger embedder re-ranks to top-10, the LLM sees the top-10. Pg-raggraph already supports cross-encoder re-ranking; the natural extension is a second-pass embedder rerank as another opt-in layer.

Both patterns suggest a future where the embedder isn't a single global config — it's a tier of embedders that compose at retrieval time. That's a meaningful API shape and it's the kind of thing where having the entire pipeline in one library (rather than spread across multiple services) makes the experimentation cheap.

## Where I think the actual perf wins are

If somebody asked me to spend a week making pg-raggraph faster *for the workloads people actually run*, I'd do this in order:

First. Ship F3 (resolution CTE) and F4 (codec registration once per connection). These are pure wins, no behavior change, ~half a day of work each. They'd show up as a 1.5-2× speedup on every short-query path including normal retrieval. Nobody loses anything.

Second. Profile the real ingest hot paths. The bake-off told me about post-extraction storage. The actual ingest with LLM extraction has a different shape — extraction is the bottleneck, not storage. We should find out empirically where the time goes when LLM extraction is dominant, not just where it goes in pure-storage benchmarks.

Third. Validate F5 (bulk_load drop+rebuild). On corpora >100K chunks, this could be a 3-5× speedup on the initial ingest. We don't have a corpus that big benchmarked yet, so the right move is to find or build one before claiming the speedup.

The Rust extension and the pg_net sidecar are interesting architectural questions, but they're 3-6 month efforts each, and the easier wins haven't been picked yet. Sequencing matters. Get the easy stuff done, build a real demand signal for the harder stuff, then commit the engineering when it's actually load-bearing.

What's your current bottleneck — ingest LLM cost, retrieval latency, or something I haven't surfaced?
