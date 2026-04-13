---
title: "Building the GraphRAG Demo: 391 SCOTUS Cases, Four Retrieval Strategies"
date: 2026-04-16
draft: false
tags: ["postgres", "rag", "graphrag", "pgvector", "apache-age", "ai", "benchmarks"]
summary: "Part 3 of 3. 391 real SCOTUS cases, four retrieval strategies running side by side, multi-hop Cypher that no hybrid search can match, and the production-ready 3-stage architecture you should actually ship."
---

> **Part 3 of 3** in the GraphRAG on Postgres series. Companion repo: [yonk-labs/graphrag-demo](https://github.com/yonk-labs/graphrag-demo). Read [Part 1](../graphrag-part1-vector-vs-graph/) and [Part 2](../graphrag-part2-postgres-age-pgvector/) first if you haven't.

You're about to wire real Supreme Court data into the stack from Part 2 and prove, with actual query results, that graph plus vector plus hybrid beats any one approach on the questions that matter. I'll show you the architecture, the dataset, the four retrieval strategies, the multi-hop query detection logic, and a handful of places where I got it wrong the first time and had to start over. By the end you'll have a working demo running on 391 real SCOTUS cases and a clear path to swap in your own data.

Fair warning: this is a walkthrough, not a copy-paste tutorial. The point is understanding why each piece exists so you can adapt it, not cargo-culting a repo and hoping. I have thoughts, and some of them are going to save you a week.

## The dataset

391 real Supreme Court cases from the 2018 through 2023 terms. Each case lives as a markdown file with a predictable structure: metadata at the top (docket number, citation, term, petitioner, respondent), then sections for Question Presented, Summary, Facts of the Case, Decision, and a Vote Breakdown listing every justice's vote. Roughly 2.5MB of text total. Ships inside the Docker image, so there are no external dependencies, no API keys, no "oh by the way you also need to clone this 40GB corpus" surprises.

From that raw text we extract five things. Case metadata becomes `Case` nodes. Per-justice votes become `VOTED_MAJORITY` and `VOTED_DISSENT` edges. Opinion authors get pulled out of the Decision text via a pile of regex patterns and become `WROTE_OPINION` edges. Issue classification runs keyword matching against a fixed taxonomy of 15 legal areas (First Amendment, Antitrust, Criminal Procedure, and so on) to create `CONCERNS` edges. And citations between cases become `CITED` edges when one case mentions another by name in its decision text. The regex for opinion authors hits about 85%. The other 15% are per curiam opinions and unusual phrasings that would need an LLM to parse cleanly. Good enough for a demo. Not good enough if you're trying to publish legal research.

Now the self-deprecating bit. The first time I built this, I used synthetic data. Fake companies, fake projects, fake incident reports, all procedurally assembled to "showcase" the retrieval strategies. It looked great in screenshots. Then I tried to prove the graph-plus-vector thesis and realized I'd correlated the content and the structure so perfectly that every strategy returned the same top five results. The demo proved nothing. Switching to real SCOTUS data was the fastest way to stop lying to myself.

## The graph schema

Here's the schema we land on, straight from `postgres/initdb/03-graph-schema.sql`:

```sql
SELECT ag_catalog.create_graph('org_graph');

-- SCOTUS labels
SELECT ag_catalog.create_vlabel('org_graph', 'Case');
SELECT ag_catalog.create_vlabel('org_graph', 'Justice');
SELECT ag_catalog.create_vlabel('org_graph', 'Issue');

SELECT ag_catalog.create_elabel('org_graph', 'VOTED_MAJORITY');
SELECT ag_catalog.create_elabel('org_graph', 'VOTED_DISSENT');
SELECT ag_catalog.create_elabel('org_graph', 'VOTED_CONCURRING');
SELECT ag_catalog.create_elabel('org_graph', 'WROTE_OPINION');
SELECT ag_catalog.create_elabel('org_graph', 'CITED');
SELECT ag_catalog.create_elabel('org_graph', 'CONCERNS');
```

Three entity types, six relationship types. That's the whole SCOTUS model. I keep pushing people to start small with graph schemas and it keeps being the right advice. If you can't explain every label to a new engineer in under two minutes, you've designed something you're going to resent in six months.

The same `org_graph` also holds a second example dataset (Person, Team, Project, Service, Technology) from an earlier iteration. AGE is perfectly happy storing multiple entity types in one graph, which lets both demos coexist on the same infrastructure.

The bridge between graph and vector is the important part, and it's simpler than you'd think. The `documents` table has two columns, `author_id` and `project_id`, which for SCOTUS docs map to a Justice id and a Case id respectively. Those ids are the same ids we use as graph node identifiers. So when vector search returns a document, you already know which graph nodes to walk from. That's how the combined strategy stitches the two worlds together: vector finds semantically similar docs, you grab the ids off the results, and then you traverse the graph from there. No separate "mapping table," no duplicated state, just the same string appearing in two places.

## The four retrieval strategies

Quick note before we get into it: the demo runs all four strategies in parallel on purpose, so you can see what each one retrieves in isolation on the same question. That's a teaching setup, not a production setup. We'll get to the production shape later in the post, once you've seen what the individual retrievers actually do.

Four strategies, one demo. Each one is a separate Python class, each one gets called in parallel from the API, and each one returns a list of `RetrievedItem` objects that the UI renders side by side.

**Vector-only** is the boring one. Embed the question, run cosine similarity via the pgvector HNSW index, return the top k. From `app/retrieval/vector.py`:

```sql
SELECT title, content, doc_type,
       1 - (embedding <=> %s::vector) AS similarity,
       author_id, project_id
FROM documents
ORDER BY embedding <=> %s::vector
LIMIT %s
```

One query. Fast. Good when the question is "find me something that looks like X."

**Hybrid** runs vector search and Postgres full-text search (BM25-style) and merges the two ranked lists with Reciprocal Rank Fusion. The FTS half looks like this:

```sql
SELECT id, title, content, doc_type,
       ts_rank_cd(
           to_tsvector('english', title || ' ' || content),
           plainto_tsquery('english', %s)
       ) AS rank
FROM documents
WHERE to_tsvector('english', title || ' ' || content) @@ plainto_tsquery('english', %s)
ORDER BY rank DESC
LIMIT %s
```

RRF is the fusion trick. Each document gets a score of `1 / (k + rank)` from each list it appears in, the scores are summed, the documents get re-sorted. k is 60 by tradition (the original RRF paper picked it and nobody has beaten it convincingly). It's elegant because it doesn't require the two scores to be on the same scale. Cosine similarity and BM25 live in completely different number spaces, but RRF doesn't care about the numbers, only the ranks.

**Graph-only** is where things get interesting. Extract entities from the question, match them against known graph entities, then decide what kind of query to run. For questions that match a single entity, walk one or two hops from it. For questions that match multiple entities (two justices, a justice and an issue, or a case), run a multi-hop pattern match.

Here's what one of those multi-hop Cypher queries actually looks like, from `_multihop_justice_justice` in `app/retrieval/graph.py`:

```python
cur.execute(
    f"SELECT * FROM cypher('org_graph', $$ "
    f"MATCH (j1:Justice {{id: '{j1_id}'}})-[:VOTED_DISSENT]->(c:Case)"
    f"<-[:VOTED_DISSENT]-(j2:Justice {{id: '{j2_id}'}}) "
    f"RETURN c.id, c.name, 'dissented together' "
    f"$$) AS (id agtype, name agtype, relation agtype);"
)
```

Read that pattern literally. "Find a case where justice one dissented AND justice two also dissented, and give me back the case." That's one query, one traversal, one answer. Now try expressing that in pgvector. Try expressing it in full-text search. You can't. You'd have to pull down every case's vote breakdown, parse each one, and intersect the results in your application code. The graph just does it as a pattern. This is where graph earns its keep, and no amount of clever embedding tricks is going to close the gap.

**Combined** (the one I've been calling GraphRAG) runs vector, hybrid, and graph in parallel, plus a graph expansion stage that takes the top vector results and walks out from them to find related cases through citation chains and shared issues. Everything gets merged and then reranked with a weighted scoring function in `app/retrieval/combined.py`:

```python
if item.source == "vector":
    combined_score = item.score * vector_weight
elif item.source == "graph":
    combined_score = item.score * graph_weight
elif item.source == "graph_expanded":
    combined_score = item.score * graph_weight * 0.7
elif item.source == "hybrid":
    combined_score = item.score * hybrid_weight * 10
```

Vector and graph each get 0.4 weight, hybrid gets 0.2 (then multiplied by 10 because RRF scores are tiny). Graph-expanded results get a 30% discount versus direct graph hits because they're second-degree matches. This is the "use all the signals and let the ranker sort it out" approach, and it's the closest thing we have to a production path.

## Multi-hop query detection

The fun part of the graph retrieval isn't the Cypher. It's the code that decides which Cypher to run.

`GraphRetrieval.retrieve` starts by loading the known-entities dictionary (every Case, Justice, and Issue in the graph) and doing case-insensitive substring matching against the question. Plus a last-name-only fallback for justices because people say "Sotomayor" more often than "Sonia Sotomayor." Then it counts how many entities matched and dispatches:

```python
justices = [(l, eid) for l, eid in matched if l == "Justice"]
issues = [(l, eid) for l, eid in matched if l == "Issue"]
cases = [(l, eid) for l, eid in matched if l == "Case"]

# Case A: Two or more justices -> cases they voted together on
if len(justices) >= 2:
    used_multihop = True
    for i in range(len(justices)):
        for j in range(i + 1, len(justices)):
            pairs = _multihop_justice_justice(
                cur, justices[i][1], justices[j][1]
            )
            ...

# Case B: Justice + Issue -> cases about issue that justice voted on
if justices and issues:
    used_multihop = True
    ...

# Case C: Case mentioned -> citation chain
if cases:
    used_multihop = True
    ...
```

If none of those patterns hit, we fall back to single-entity traversal: walk one and two hops from each matched entity and return whatever docs are attached.

So what does that actually mean? It means intent detection in this demo is basically a partition of the matched entities by label, with a hardcoded dispatch table. That's it. There's no LLM parsing the question, no fancy NL-to-Cypher translator. It's substring matching plus a decision tree. A proper production system would use an LLM to generate the Cypher directly, which is a real pattern called text-to-Cypher. But for a demo, and honestly for a lot of real apps where the query vocabulary is predictable, this minimum-viable version gets you maybe 80% of the value at maybe 1% of the cost. Don't reach for an LLM when a dispatch table will do.

## What production should actually look like

Okay. You've seen what each retriever does on its own and how the combined path stitches them together. Time to pay off the caveat from earlier. The parallel-merge pattern you just watched is a great teaching tool and a lousy production architecture, and the benchmark numbers are why. I'm not going to let you walk away thinking "dump four retrievers into a ranker" is the production answer, because I ran the comparison myself and it isn't.

Here's the shape of the production architecture, the one you'd actually build if you were shipping this to paying users:

```
Query
  │
  ▼
Stage 1: Vector + BM25     (ALWAYS, ~20-30ms)
  │  Top-K chunks by semantic + keyword relevance.
  │
  ▼
Stage 2: Graph Boost       (CHEAP, +~10ms)
  │  For each entity mentioned in the top-K chunks,
  │  look up 1-hop neighbors in the graph and re-rank.
  │  Chunks that mention a neighbor entity get score * 1.2.
  │
  ▼
Stage 3: Graph Expand      (EXPENSIVE, CONDITIONAL, +30-60ms)
  │  Only runs when:
  │    - user explicitly asks for expand mode, or
  │    - top-K vector scores are all weak (below threshold), or
  │    - query matches a graph-shaped pattern
  │      ("who voted with", "what depends on", "who owns")
  │
  ▼
Return
```

Three stages, and the interesting design decision is which stage runs on which query. Stage 1 runs on every query, always. Stage 2 runs on every query too, but it's cheap because it's just a 1-hop neighbor lookup for a handful of entities and a score re-weight. Stage 3 runs only when the query earns it.

So why is this better than the parallel-merge thing you just watched the demo do? Start with the obvious one: the fast path actually stays fast. On a question like "what cases deal with administrative overreach," Stage 3 never fires at all, Stage 2 adds about 10ms of neighbor lookups, and your query completes in roughly 30 milliseconds total because vector+BM25 is carrying almost everything. You don't pay graph-expand latency on questions that gain nothing from graph-expand. Parallel-merge pays it every time.

The second win is more subtle and it matters more. In parallel-merge, graph results get ranked against vector results and some merge function has to decide who wins. That's exactly where graph can hurt you on the wrong question, because a weak graph hit will push a strong vector hit off the page. The 3-stage arrangement never lets that happen, because graph isn't competing for a spot on the list. It's adjusting the scores of chunks that were already on the list. The ranker cannot get confused by a retriever it isn't talking to.

And then Stage 3, when it runs, runs all the way. No fuzzing a multi-hop pattern match into a ranked list and praying RRF sorts it out. If your query earned Stage 3, you get proper Cypher, a structural answer, and that answer goes straight to the top of the result list because it actually answers the question, not because it happened to tie with a hybrid search.

The benchmark numbers from Part 1 are what sold me on this. Vector+BM25 alone landed somewhere between 75% and 90% accuracy on the bulk of the test set. Adding graph as a boost on the questions that need multi-hop reasoning moved the needle another few points, on the order of a single-digit bump. Slapping graph in as a parallel retriever on questions that didn't need it actually made things worse by a couple of points, thanks to dilution. The 3-stage architecture is how you collect the upside from the multi-hop questions without eating the downside everywhere else. Same numbers we saw in Part 1, different arrangement, very different result.

Here's what Stage 2 looks like in pseudocode, just to make the shape concrete:

```python
def stage2_graph_boost(top_k_chunks, cur):
    # Collect entity ids mentioned in the top-K chunks
    entity_ids = set()
    for chunk in top_k_chunks:
        entity_ids.update(chunk.entity_ids)

    # One-hop neighbor lookup in AGE, cheap
    neighbors = cypher_one_hop(cur, entity_ids)
    # neighbors: set of entity ids within 1 hop of any top-K entity

    # Re-rank: bump chunks that mention a neighbor
    for chunk in top_k_chunks:
        if chunk.entity_ids & neighbors:
            chunk.score *= 1.2

    return sorted(top_k_chunks, key=lambda c: -c.score)
```

And Stage 3, the conditional expand:

```python
def should_run_stage3(query, top_k_chunks):
    if query.mode == "expand":
        return True
    if max(c.score for c in top_k_chunks) < WEAK_THRESHOLD:
        return True
    if matches_graph_pattern(query.text):
        # "who voted with", "what depends on", "who owns", ...
        return True
    return False

def stage3_graph_expand(query, cur):
    # Real multi-hop Cypher, same as GraphRetrieval in the demo
    return run_multihop_cypher(query, cur)
```

That's the production path. The demo doesn't run this because the demo is showing you what each retriever returns in isolation. Our "combined" strategy is intentionally more aggressive than a production pipeline should be. It's showing off capability, not optimizing for precision. Copy the combined strategy verbatim into your product and you'll watch that dilution effect quietly eat a chunk of your questions, and then you'll wonder why your benchmark numbers got worse after you added graph. They got worse because you added graph to the ranker instead of to the re-rank step. Don't do that. Do 3-stage.

## The side-by-side demo UI

The UI is deliberately boring. A FastAPI static page at `http://localhost:8000` with a search bar, a row of pre-loaded example queries, and four columns labeled Vector, Hybrid, Graph, and Graph+Vector+Hybrid. Hit an example or type your own, and all four columns fill in simultaneously with the retrieved results, the LLM-generated answer, and a little stacked bar chart showing where each strategy spent its time (embedding, vector search, graph traversal, reranking, LLM generation).

The example queries come from `EXAMPLE_QUERIES` in `app/main.py` and each one carries a dataset badge (acme or scotus) so you can tell which world you're in. The ACME examples exercise the knowledge-base side (ownership chains, blast radius). The SCOTUS examples exercise the judicial side (justice voting patterns, issue intersections, multi-hop pattern matching). When you run one of the multi-hop SCOTUS queries, you can watch the graph column pull ahead of the others visibly, which is the single most satisfying thing I've put in a demo UI this year.

I built this UI specifically to avoid the thing I hate about most RAG demos, where they show you the winning answer and hide the losers. My first version was a single answer box with a dropdown to pick the strategy. I stared at it for an hour, felt dumb, and rewrote it as four columns. The comparison was the whole point and I'd almost hidden it behind a select element. I do this kind of thing constantly.

## Real query results

Enough setup. Let's run three queries and see what actually comes back.

### Query 1: "Find cases about administrative overreach"

Vector wins this cleanly. The question is pure topical match and vector is built for exactly that. The top results are cases where administrative agency authority was the central issue, pulled in by semantic similarity between the question and the case summaries. Hybrid adds a small bump from FTS matching the word "administrative" but the results are mostly the same set reordered. Graph returns nothing useful because the question doesn't name any specific entity; "administrative overreach" isn't a Justice, Case, or Issue, it's a theme. And combined ends up dominated by vector because that's where the relevant signal lives.

The lesson is the one nobody wants to hear: you don't need graph for this question. Vector or hybrid is enough. If every question your users ask is some version of "find me stuff about X," close this tab, go add pgvector to your app, and ship your feature. The graph machinery is overhead you don't need.

The graph starts earning its keep when the questions get weirder.

### Query 2: "Which cases did Justice Thomas and Justice Sotomayor vote together on?"

This is the one I built the demo around, so I want to walk through it carefully.

Vector returns documents that are semantically close to "voting" and "together." You get Colorado Department of State v. Baca (a case about faithless electors), Acheson Hotels v. Laufer (about a plaintiff's standing to sue), and a handful of other docs where the content talks about voting in some generic sense. These are topical matches. They do not answer the question. The question is asking for an intersection of two voting relationships, and nothing in the embedding space encodes that intersection because nobody writes case summaries that say "Justice Thomas and Justice Sotomayor voted together on this one."

Hybrid returns roughly the same set. The FTS boost helps with literal keyword matches on "Thomas" and "Sotomayor," which nudges a couple of results up, but the top docs are still semantically-related-to-voting rather than structurally-answering-the-question.

Graph runs the multi-hop Cypher from earlier (the `(:Justice)-[:VOTED_MAJORITY]->(:Case)<-[:VOTED_MAJORITY]-(:Justice)` pattern) and returns the actual cases where both justices were in the majority together: Muldrow v. City of St. Louis, Moody v. NetChoice, McIntosh v. United States, and the other cases that genuinely match. Each result carries an explanation string: "Multi-hop pattern match: voted majority together." That's not a guess from semantic similarity. That's a structural answer pulled from a pattern match.

Combined interleaves vector, hybrid, and graph. Because graph results score 0.95 on these pattern-match queries and vector results typically score 0.6 to 0.8 on cosine similarity, the graph results rise to the top of the merged list. You get the structural answer first and the topical context second.

Look, this is the demo. The graph does in 13 milliseconds what no hybrid search on earth can do correctly in any number of queries. When the question is an intersection of relationships, the right tool is the one that models relationships as a first-class citizen. That's not a hot take. That's just what the data structure is for.

### Query 3: "What First Amendment cases did Justice Sotomayor vote on?"

Justice plus Issue. This hits the `_multihop_justice_issue` branch, which runs a pattern that walks from the Justice node through a vote edge to a Case and then through a CONCERNS edge to the Issue node for First Amendment. Graph returns the exact set of cases where Sotomayor voted and the case concerned the First Amendment. Vector returns cases with the words "First Amendment" and "Sotomayor" somewhere in the text, which overlaps but isn't the same set and isn't ordered by the actual question. Combined picks up the graph results and uses vector to fill in context.

This is the second thing that makes the demo sing: any query that needs to intersect two different kinds of relationships (person plus topic, person plus time, entity plus property) gets much better answers from a graph than from a keyword or semantic search. If you're building something where users are going to ask "show me X from Y" or "which Xs are related to both Y and Z," you already need a graph. You just don't know it yet.

## Performance observations

Real numbers from verified runs on my laptop:

- **Vector** runs in about 40ms end to end once the embedding model is warm. The first query after startup pays a ~1000ms penalty while sentence-transformers loads its weights. Cache the model, warm it at startup, and you never see that cost again. (If you see it on every query, your container is thrashing and you have a memory problem.)
- **Hybrid** takes roughly 2x vector alone because it runs two index scans (HNSW and GIN) and then fuses the results. The RRF fusion itself is microseconds. The bottleneck is running two queries.
- **Graph** runs in 5 to 15 milliseconds for multi-hop Cypher patterns because AGE compiles them to native Postgres operators against indexed vertex and edge tables. Entity extraction on the question adds 1 to 3 milliseconds. The total graph path is often faster than vector because it doesn't have to embed anything.
- **Combined** is roughly the max of the four component paths plus a small reranking step, so 40 to 80 milliseconds after warmup. It runs the four strategies in a thread pool, so the costs overlap rather than stack.

One note on the parallel-merge cost in the demo. Running all four retrievers in parallel still costs you the max latency of the four plus the reranking step, because your response can't go out until the slowest retriever finishes. In the 3-stage production architecture from earlier, most queries never fire Stage 3 at all, which means most queries complete in roughly 30 milliseconds total. The only queries that eat the extra 30 to 60 milliseconds are the ones where the query shape actually needs a graph, and on those queries you were going to pay the cost anyway. Parallel-merge pays the graph cost on every query. 3-stage pays it only when it matters.

The pattern I keep hammering: graph queries are fast when your graph is modeled right, because most graph questions only touch a handful of nodes. The slow part isn't the database, it's the embedding model. Cache it, warm it, batch the seed inserts.

## Adapting this to your own dataset

Here's the replication path for the reader who wants to swap in their own problem:

1. **Design your entity types and relationships first.** What are the nouns in your domain? What are the verbs? Aim for 3 to 8 entity types and 4 to 10 edge types. If you're tempted to go above that, stop and ask which ones you actually need for the questions you want to answer. Over-schema is the most common way I've seen graph projects die.
2. **Add your vertex and edge labels** in `postgres/initdb/03-graph-schema.sql`. One `create_vlabel` per entity, one `create_elabel` per relationship.
3. **Write a parser for your raw data.** Ours is a markdown parser in `app/seed/scotus_data.py`, but it could be JSON, CSV, database queries, or API calls. Output the same structure: a list of nodes per label, a list of edges per label, and a list of documents where each document has `author_id`, `project_id`, and `dataset` fields that reference graph node ids.
4. **Update `app/seed/seed.py`** to call your loader and insert the data. Copy the patterns from the SCOTUS loader.
5. **Add multi-hop pattern functions** to `app/retrieval/graph.py` for the relationships your queries will follow. One function per query pattern. Wire them into the dispatch block in `GraphRetrieval.retrieve`.
6. **Add example queries** in `app/main.py` that exercise each strategy so you can compare them side by side in the UI.
7. **Run, query, break, iterate.** The first schema is never right. Mine wasn't. Yours won't be either.

The hardest step is step one, and I can't do it for you from a blog post. Take time on it. Draw the nodes on paper before you touch SQL. Your schema determines which questions you can ask, and adding an edge type later is cheap, but restructuring after you've indexed a million documents is not.

## Where we'd go next

Things I'd do if this were a production system instead of a demo:

1. **Adopt the 3-stage retrieval architecture.** This is the number-one change and it's not close. Our demo's combined strategy runs vector, hybrid, graph, and graph-expand in parallel and merges them through a weighted ranker. That's a teaching pattern, not a production pattern. Production is Stage 1 vector+BM25 always on, Stage 2 cheap graph boost via 1-hop neighbor re-ranking, Stage 3 expensive graph expand only when the query shape or vector confidence says it's worth it. The combined path in this demo is intentionally aggressive because it's showing capability. Don't ship it as-is.
2. **Text-to-Cypher with an LLM.** Substring matching plus a dispatch table is fine for a small number of query shapes. For a real product where users can ask anything, let an LLM generate the Cypher from the question. It's the right tool for the job, and it plugs naturally into Stage 3 of the architecture above.
3. **Cross-encoder reranking.** RRF is decent. A cross-encoder model that scores (query, document) pairs on the top 20 to 50 results is measurably better. Add it after Stage 2 and before the final top k.
4. **Cache entity lookups.** We reload the full known-entities dict from the graph on every query. It's small so it doesn't matter, but in a graph with millions of entities you'd precompute a name-to-id index or use a bloom filter.
5. **Embedding model as a dedicated service.** Running sentence-transformers inside the API container is fine for a demo. For production, move it out, batch requests, and run it on hardware that actually wants to do matmul.
6. **Real distributed tracing.** We have stage timings per query, which is cute, but debugging a production RAG pipeline needs OpenTelemetry spans across the whole request. Do that from day one. You'll thank yourself.

None of this is exotic. The demo skips it because the demo is about showing the retrieval strategies, not shipping a product. Don't confuse the two.

## Your turn

Clone the repo. Run `docker compose up`. Ask your own questions. If every strategy returns the same top five results, your questions are too easy or your data is too correlated. Find a question where the strategies disagree. That's the one that matters. That's the question where your users get bad answers today and where a graph is going to rescue you tomorrow.

Where I'd start: pull a week of query logs from whatever app you're building. Find the questions that start with "who," "which," or "what depends on." Run those through the demo with your data loaded. I'll bet you a coffee that at least a fifth of them return completely different top results from graph versus vector. Those are the ones you're answering badly right now, and they're fixable with 200 lines of Cypher and a weekend of schema design.

And once you've broken the demo version, build the 3-stage version on your own dataset. Vector+BM25 always on, cheap graph boost in the middle, expensive graph expand only when the query earns it. That's the shape you'll actually ship. If you do it and the numbers move, I want to hear about it.

Now stop reading and go break it. If you find something weird, or something better than what I built, tell me about it. The HOSS wants to see it.
