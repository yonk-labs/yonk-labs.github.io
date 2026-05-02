---
title: "pg-raggraph and Apache AGE solve different problems. Stop comparing them on the wrong axis."
date: 2026-05-07
draft: false
tags: ["pg-raggraph", "apache-age", "graphrag", "postgres", "rag", "ai"]
summary: "AGE is a property-graph engine; pg-raggraph is read-mostly retrieval that combines vector + BM25 + shallow graph traversal in one query plan. Where each wins, where neither fits, and the deployment story that closes off most of the postgres install base."
build:
  list: never
---

Every time I post about pg-raggraph somebody asks "why didn't you use Apache AGE?" The honest answer is that AGE and pg-raggraph aren't competing for the same job. They're competing the way a sports car and a pickup truck compete — they look like vehicles to somebody who doesn't drive much, but if you're trying to haul lumber, the question of "which one is faster around the track" is the wrong frame.

I'm going to lay out where AGE wins, where pg-raggraph wins, and where you almost certainly don't need either of them. And I'm going to do it without trash-talking AGE, because AGE is a real piece of engineering and the people working on it are smart. The problem is people mis-deploy it for jobs it isn't shaped for.

## What Apache AGE actually is

AGE is a Postgres extension that adds a property-graph engine to your database. Real Cypher support (the openCypher dialect). First-class graph types — vertices, edges, paths, with arbitrary properties on each. Graph algorithms via the cypher language: shortest path, BFS, DFS, all-paths-between. The whole "social network analysis" / "knowledge graph in production" toolkit, sitting inside your postgres instance instead of a separate Neo4j cluster.

Three things AGE is genuinely great at, and you should consider it for:

**Graph algorithm workloads.** PageRank, community detection, centrality measures, shortest-path queries on networks with millions of nodes. If you're doing fraud detection on a transaction graph, or computing influence scores on a social graph, or doing supply-chain risk analysis where you need to traverse 5+ hops — AGE is purpose-built for this and the Cypher language is the right tool. SQL recursive CTEs *can* do shortest-path, but they're awkward for it; Cypher is cleaner and the AGE engine is optimized for the access pattern.

**Property-graph applications where the graph is the source of truth.** Identity resolution. Org-chart traversal. Permission graphs ("can user X read resource Y given the chain of group memberships and role inheritances"). Anywhere your *application logic* is a graph algorithm, not a side computation. The schema flexibility of arbitrary edge/node properties matters a lot here.

**Teams already comfortable with Cypher.** If you have engineers who came from Neo4j and think in Cypher, AGE lets them write the same patterns inside postgres. That's a real productivity argument — language fluency is a thing.

I want to be clear: AGE works. The community ships releases. The Cypher engine is real. None of what follows is a critique of the project itself.

## Where AGE doesn't fit — and why pg-raggraph exists

GraphRAG is not a graph algorithm workload. It's read-mostly retrieval where the graph augments vector similarity. Three properties of GraphRAG retrieval that turn out to matter:

1. The graph traversal is shallow. 1-3 hops, almost never deeper. Multi-hop QA datasets (MuSiQue, HotpotQA) cap out at 4 hops by construction, and our own benchmarks showed full 1-3 hop traversal *hurts* on hard 4-hop questions because deep traversal pulls in noise. The hop budget you actually use is small.

2. The retrieval combines graph traversal with vector cosine similarity in the same query. A typical GraphRAG query: "find chunks with cosine similarity > 0.6 to this question, expand by 2 hops through shared entities, score by combined vector + graph signal, return top-10." That's a single retrieval operation that needs both signals simultaneously.

3. The result set is documents (chunks), not graph paths. You don't care about the path *as such* — you care that the chunk you retrieve is relevant. The graph is plumbing, not output.

Here's the AGE structural problem for this workload. AGE's Cypher and pgvector cannot combine in a single query. They're separate query languages with separate execution paths. If you want vector similarity on chunk embeddings AND graph traversal through entity edges, you do two queries — one for each — and merge results in your application. That's a round-trip, a marshalling cost, and a query plan that postgres can't optimize across the boundary. (I've watched somebody try to wrap it in a stored procedure. The plan estimates were off by orders of magnitude. We backed it out.)

pg-raggraph's design avoids this by storing the graph in adjacency tables (`entities`, `relationships`, with proper btree indexes on src_id/dst_id) and using recursive CTEs for traversal. Recursive CTEs are pure SQL. They compose with pgvector. A single query combines vector similarity, BM25 keyword search, and 2-hop graph traversal in one execution plan that the postgres planner can optimize end-to-end.

The benchmarks bear this out. On the SCOTUS legal-QA bake-off (779 chunks, 416 entities, 4,397 relationships, 30 questions × 3 runs × gpt-5-mini majority-of-3 judge), pg-raggraph and AGE land at parity on accuracy, but pg-raggraph runs retrieval **42-111× faster** depending on the mode — pgrg's slowest mode (hybrid p95 = 90ms) is 42× faster than AGE's fastest (hybrid p50 = 3088ms). Same graph, same chunks, same embedder. The architectural difference is the gap.

## The deployment-availability story

This is where I usually lose people, but it's the most important part for anybody planning a deployment.

AGE requires `shared_preload_libraries`. That's a postgres GUC that has to be set at server startup, requires a database restart to change, and *requires superuser permission to even attempt*. On managed postgres providers, this is a wall:

- AWS RDS: AGE is not in the supported extensions list. You can request it, but as of mid-2026 it isn't there.
- GCP Cloud SQL: Not supported.
- Supabase: Not supported.
- Neon: Not supported.
- Azure Database for PostgreSQL: AGE *is* supported (this is the one provider where AGE works out of the box).

If your postgres lives on RDS or Cloud SQL or Supabase or Neon — and it probably does, because that's where most postgres lives in 2026 — AGE is not an option. Not "harder to deploy." Not an option. You'd have to migrate to a self-hosted postgres or to Azure to use it.

pg-raggraph requires `pgvector` and `pg_trgm`. Both are first-class on every managed provider I've checked. RDS, Cloud SQL, Supabase, Neon, Azure — pgvector ships in the default extension set. The deployment story for pg-raggraph is "your postgres already has the extensions; install the python package."

This isn't a knock on AGE — `shared_preload_libraries` is a real Postgres feature with real reasons (some extensions need server-process hooks). It's a structural choice the AGE team made. But it imposes a deployment constraint that closes off most of the postgres install base for retrieval-shaped workloads where AGE's other features aren't actually being used.

## The honest decision matrix

Three rules of thumb, because everything comes in threes.

**Use Apache AGE when** your workload is graph-shaped — algorithms over the graph are the actual product (fraud detection, identity resolution, network analysis), Cypher is your team's lingua franca, you're on Azure or self-hosted postgres where you can install the extension, and you're not blending graph queries with pgvector similarity in the hot path.

**Use pg-raggraph when** your workload is RAG-shaped — read-mostly retrieval, vector similarity is the primary signal, the graph is augmentation not the main act, you need to combine vector + graph + BM25 in single queries, and you want to deploy on whatever postgres you already have without provisioning a graph extension.

**Use neither when** your data lives in flat documents that don't share entities across each other (NTSB-style hermetic narratives, customer reviews, news articles). Pure vector retrieval with a reranker is enough. Don't pay the LLM cost of entity extraction or the operational cost of either system. The +18.9% accuracy lift from graph mode on the dev-codebase corpus isn't a universal property; it's a corpus-shape result. Hermetic content gets ~0% lift from either.

## Where they could compose

There's a corner of the world where AGE and pg-raggraph could conceivably live together. You're doing real graph algorithms (PageRank on a customer-product-purchase graph, say) AND you also need RAG over the unstructured text associated with those entities. AGE owns the graph-algorithm side. pg-raggraph owns the retrieval side. Same postgres instance, different schemas, different access patterns.

I haven't seen anybody actually deploy this combination in production, but the architecture is clean. The two systems don't fight each other because they're optimizing different things — AGE optimizes for graph traversal cost over property graphs, pg-raggraph optimizes for vector similarity over chunks plus shallow adjacency joins. Different indexes, different access patterns, no contention.

If you're in that corner, the answer might be "both." Most teams aren't in that corner.

## What I'd push back on

If somebody on your team is making the "we need AGE for GraphRAG" argument, the question I'd ask them is "what specific operation in our retrieval pipeline requires Cypher or property-graph semantics that we couldn't do in SQL?" If the answer is "the graph traversal," that's a recursive CTE — postgres has had those since 8.4 (2009). If the answer is "we need to combine the graph with vector search," that's exactly the operation AGE *can't do in one query*. If the answer is "the team is already comfortable with Cypher," that's a real argument and you should weigh it. If the answer is "Microsoft's GraphRAG paper used a graph database," go re-read the paper — Microsoft's reference implementation uses LanceDB and Parquet files, not a property graph engine.

I've made this argument enough times to be tired of it, but it keeps mattering. The default architectural reach for GraphRAG is "stand up a graph database." The architecture you actually need is usually one rung simpler than that, and you save yourself a deployment pain that doesn't pay you back.

What's the actual graph operation in your RAG pipeline that needs more than a recursive CTE?
