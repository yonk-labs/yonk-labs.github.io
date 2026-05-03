---
title: "GraphRAG without a graph database. Yes, in postgres."
date: 2026-05-05
draft: false
tags: ["pg-raggraph", "graphrag", "postgres", "pgvector", "rag", "ai"]
summary: "Most teams reach for Neo4j or Apache AGE the moment they read the Microsoft GraphRAG paper. The honest answer is most GraphRAG workloads don't need a graph database — pgvector + recursive CTEs + tsvector handle 1-3 hop traversal in one ACID database."
build:
  list: never
---

Hot take to start: most teams I talk to about GraphRAG are picking the wrong fight. They read the Microsoft GraphRAG paper, get excited about entity-relationship retrieval, and then the architecture conversation immediately becomes "OK so we need to stand up Neo4j" or "let's evaluate Apache AGE" or "should we look at TigerGraph." Three different graph databases on the table before anybody has asked whether the actual workload needs a graph database at all.

It usually doesn't.

I've been building [pg-raggraph](https://github.com/yonk-labs/pg-raggraph) for the last several months. It's a GraphRAG library that runs entirely in PostgreSQL — pgvector for the vector side, adjacency tables and recursive CTEs for the graph side, BM25 via tsvector for keyword search, all in one ACID-compliant database. No graph extension required. No second backup strategy. No data sync between two systems.

This isn't an academic exercise. The library has been benchmarked across six corpora at this point — postgres docs, NTSB aviation reports, sales call notes, MuSiQue multi-hop QA, the Python 3.x docs across versions, and PubMed HRT abstracts. The numbers are competitive with or better than the GraphRAG-on-graph-DB stacks for the workloads where graph augmentation actually pays off, and they don't blow up when somebody hands you an AWS RDS instance and says "deploy this here." (Try doing that with Apache AGE. I'll wait.)

Three things I want to walk through. What pg-raggraph actually is. Where it overlaps with and differs from Microsoft GraphRAG. And three real use cases where it earns its keep — including one where it doesn't, because being honest about where a tool loses is more useful than handing somebody a tool that's wrong for them.

## The setup, in two minutes

GraphRAG as a pattern looks like this. You ingest documents. You extract entities (people, products, places, concepts) and relationships (works-for, depends-on, supersedes) from each document using an LLM. You build a graph where entities are nodes and relationships are edges. At query time, you don't just do vector retrieval — you also walk the graph from documents that match the query to find related documents that share entities. The "global" view of the graph augments the local vector matches.

The Microsoft paper's core insight is that for multi-document reasoning ("what's the most common pattern across our customers?", "how did this regulation evolve over time?"), pure vector retrieval fails. Each chunk doesn't know about the other chunks. The graph is what stitches them together.

The standard implementation answer is "build the graph in a graph database." That's where I think most teams pick wrong.

Here's what a GraphRAG retrieval actually needs:
1. Vector similarity over chunk embeddings — pgvector handles this in 2-3ms per query.
2. Graph traversal from seed entities — recursive CTEs over an adjacency table handle 1-3 hop traversals in 30-100ms, which is the hop budget GraphRAG actually uses in practice.
3. Combining both in one query plan — Postgres does this trivially because everything is just SQL.

Notice what's not in that list. Cypher. Apache AGE's typed-edge primitives. A separate query language for the graph side. Centrality algorithms operating on the property graph. None of that is on the GraphRAG hot path. Your graph database is doing the heavy lifting on a workload that doesn't need it.

I burned a lot of time on this because I'd internalized "GraphRAG = graph database" without checking the assumption. When I actually looked at our retrieval profiler — vector cosine + a 2-hop traversal + a result merge — there wasn't a single operation that needed a property graph engine.

## How pg-raggraph differs from Microsoft GraphRAG

Same conceptual stack. Different storage, different cost shape, different deployment story.

Microsoft GraphRAG ships as a Python pipeline with LanceDB underneath, Parquet files for intermediate state, and a DataShaper-driven indexing flow. It's well-engineered. It's also a separate stack to operate. If your data already lives in postgres (and most of the data I see in real companies does), you have to ETL out, run the pipeline, then ETL back to make the graph queryable from your application.

pg-raggraph keeps the entire pipeline in one database. The schema is six tables — documents, chunks, entities, relationships, plus two provenance junction tables (entity_chunks, relationship_chunks) that link extractions back to their source. Indexes are HNSW for vectors, GIN for tsvector + pg_trgm fuzzy matching, btree for the adjacency joins. That's it. If you have postgres, you can `pip install pg-raggraph` and start ingesting. Same instance your application talks to. Same connection pool. Same backup story.

Three things that are noticeably different from Microsoft's design once you start using both:

**Smart-mode routing instead of community summaries.** Microsoft GraphRAG generates community-level summaries upfront — Leiden clustering on the entity graph, then LLM-summarize each community, then retrieve over those summaries for global queries. It's elegant. It's also expensive at ingest time and brittle when entities shift. pg-raggraph picks a different shape: a confidence-routed `smart` mode that runs naive vector retrieval first, escalates to graph traversal only when confidence is low, and routes aggregation-shaped questions ("most common reason we win", "patterns across deals") directly to a global relationship-centric mode. Less precomputation. More query-time decisions. Cheaper ingest, comparable retrieval quality on the corpora I've benchmarked.

**Tier 1 evolution awareness.** GraphRAG doesn't have a first-class story for "this fact was retracted" or "this version was superseded." pg-raggraph does. Documents carry effective_from / retracted / version_label columns, and retrieval can do `as_of=2024-01-01` time-travel queries or `retracted_behavior="hide"` filters. This was the difference between "it works on a snapshot" and "it works on a corpus that updates monthly" for one of the medical knowledge bases I benchmarked.

**Per-mode tunability instead of one query path.** GraphRAG has local vs global. pg-raggraph has six modes: `naive`, `naive_boost` (1-hop graph re-rank), `local` (vector seed + graph expansion), `global` (relationship-centric), `hybrid` (local + global merged), and `smart` (the router). Different corpus shapes reward different modes. The MuSiQue benchmark surfaced this: full hybrid traversal *hurts* on 4-hop questions because deep multi-hop pulls in noise. `naive_boost` (just one hop of graph re-rank) wins. Without the per-mode dispatch you'd be tuning by hyperparameter; with it you have explicit knobs.

## Three use cases where it earns its keep

**Use case one: developer knowledge base.** This is the one I built it for originally. A 909-document developer codebase corpus — service runbooks, architecture docs, on-call notes, ADRs, postmortems, the works. The questions are stuff like "who owns the billing service" or "what's the auth pattern for internal APIs" or "what happened during the May 2024 incident." These chain across documents through shared entities — services point to teams, teams point to people, incidents point to services and root causes. Vector-only retrieval misses the chain.

The benchmark on this corpus: graph mode delivered +18.9 percentage points of accuracy over naive vector retrieval. That's not a noisy 2-3 point lift; that's a meaningful difference. The shape of the data — entity-dense, multi-doc-chained, every doc has 5+ shared entities with neighbors — is exactly where graph augmentation pays off.

If your team has a knowledge base that looks like this (and most engineering orgs do — Notion + GitHub + Confluence + on-call runbooks), pg-raggraph is straightforwardly worth running. The cookbook walkthrough at [`docs/cookbook/sales-crm-ingestion.md`](https://github.com/yonk-labs/pg-raggraph/blob/main/docs/cookbook/sales-crm-ingestion.md) is the closest example, even though the example uses sales call notes — the pipeline is the same shape.

**Use case two: versioned documentation.** Postgres docs across major versions. Python docs across versions. Cloud SDK docs across SDK versions. Anywhere the answer to "how do I do X" depends on which version the user is on.

Tier 1 evolution awareness drops cleanly into this. Documents carry a `version_label` column. Retrieval gets a `version_filter="3.11"` kwarg. The same query against the same corpus returns different chunks for different versions. The benchmark we ran against Python 3.10/3.11/3.12 docs hit 100% filter purity (13/13 questions) — never returned a chunk from the wrong version. Pure vector retrieval would have to either (a) build a separate index per version (expensive at ingest, complicates the application) or (b) hope the version label appears in the chunk text often enough to be retrievable (it doesn't).

This is a use case where the graph isn't doing the heavy lifting — the version metadata is. But the graph is *still* there, and "what changed between 3.10 and 3.11" can compose with the version filter and the relationship traversal in a single SQL query.

**Use case three: where it doesn't earn its keep.** I have to call this out because it's the most useful piece of feedback for somebody evaluating the library.

The NTSB aviation incident corpus. Self-contained narrative reports — each report has the pilot, weather, aircraft, accident sequence, probable cause all in one document. Cross-incident questions like "what role did pilot fatigue play" still answer correctly via pure vector retrieval because each report is hermetic. Graph mode added basically nothing. Naive vector retrieval scored as well as full hybrid traversal.

This isn't a bug. It's a corpus-shape result. When each document is a complete narrative and the entity overlap across documents is light, graph augmentation has nothing to add. The +18.9% lift on the dev codebase isn't a universal property of pg-raggraph; it's a property of multi-document, entity-dense corpora.

If your data is hermetic narratives — incident reports, customer reviews, news articles, support ticket resolutions — graph mode is overhead. Use vector retrieval and a reranker, and don't pay the ingest cost of LLM entity extraction.

## So when do you actually want this thing

Three signals.

First, your data is in postgres or could be. If you're running on cloud-managed postgres (RDS, Cloud SQL, Supabase, Neon), pg-raggraph just works — it only needs pgvector and pg_trgm extensions, both of which are first-class on every managed provider I've checked. If you're running a self-hosted postgres, even simpler.

Second, your queries cross documents through shared entities. "What did our customers say about Product X" — yes. "Who reports to who across these org charts" — yes. "Which incidents share the same root-cause service" — absolutely yes. "What did this one document say about feature X" — no, that's a single-document lookup, vector retrieval is enough.

Third, you don't want to operate a graph database. If you're already running Neo4j and it's part of your stack, fine, use it. But if the alternative is "stand up a new database to do GraphRAG," and the GraphRAG workload is read-mostly retrieval (not graph algorithms or social-network analysis), pg-raggraph is the right answer.

I've been wrong about this before — I've watched teams deploy graph databases for read-mostly RAG workloads and then quietly migrate off them six months later because the operational tax wasn't worth it. The data engineering layer is where most RAG performance is hiding. Getting the chunker and the embedder right matters more than whether your graph lives in postgres or Neo4j. Get the data layer right first, then decide if you need a separate graph engine for whatever specific workload it actually serves.

What's the read-mostly RAG workload you're running today, and is it actually using anything your graph database is uniquely good at?
