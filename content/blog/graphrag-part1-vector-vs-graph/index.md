---
title: "Vector+BM25 Is the Floor. Graph Is the Multiplier."
date: 2026-04-14
draft: false
tags: ["postgres", "rag", "graphrag", "pgvector", "apache-age", "ai"]
summary: "Part 1 of 3. Users ask three shapes of questions and only one of them needs a graph. Honest benchmarks, a 3-stage retrieval architecture, and why graph is a multiplier — not a replacement."
---

> **Part 1 of 3** in the GraphRAG on Postgres series. Companion repo: [yonk-labs/graphrag-demo](https://github.com/yonk-labs/graphrag-demo).

So you built a RAG pipeline. You stacked pgvector on top of Postgres, wired it to an embedding model, hooked it to your favorite LLM, and shipped it to a handful of real users. For a week you felt like a wizard. Then somebody asked, "who voted with Sotomayor on First Amendment cases last term?" and your shiny system coughed up three dissent paragraphs that don't actually name a single justice. Your users stopped asking clever questions and started asking, politely, whether the whole thing is broken.

I've built this exact broken thing. More than once. (I'm not proud of it, but pretending otherwise would be a bad look for someone who's been working on databases for 20+ years.) The reason it keeps happening isn't that vector search is bad. Vector search is great at what it does. The problem is that your users don't ask one kind of question. They ask three. Two of those shapes live entirely in the text, and vector plus BM25 can handle them cold. The third needs a graph, but only sometimes, and only if you apply it with a little bit of care.

That last bit is the part I want you to walk away with, because I had to learn it the hard way. Graph retrieval isn't a replacement for vector search. It isn't even a peer. It's a multiplier you bolt onto the side of a vector+BM25 pipeline, and if you stick it in the wrong place, it actively makes your answers worse.

## Three kinds of questions, and the 80/20 that comes with them

Here's the deal. Every production RAG system I've looked at eventually runs into the same split. Users ask semantic questions, they ask keyword questions, and they ask relationship questions. Those aren't marketing buckets I made up on a whiteboard. They're the three shapes real queries take. But they don't show up in equal proportions, and that matters a lot more than I gave it credit for when I started building this thing.

**Kind 1: "Find me something like this."** The user has a vibe, a topic, a concept. They don't know the exact words in the document, and they don't care. "What cases deal with administrative overreach?" is a semantic question. The phrase "administrative overreach" might not appear anywhere in the actual ruling, but the concept does. This is exactly what vector search was built for. You embed the query, you embed the documents, you run a cosine similarity lookup, and pgvector hands you back the top matches in milliseconds. Meaning, not exact wording.

**Kind 2: "Find me exactly this."** Now the user wants a specific string. A case number. An error code. A product SKU. A legal citation like `410 U.S. 113`. Vector search is surprisingly bad at this, because embedding models round off rare tokens. The numbers and codes that matter most to your users are the tokens the model has the least signal on. BM25 and full-text search were made for this. Postgres ships `tsvector` and `tsquery` for free. Turn them on, fuse the ranks with RRF, and you've got a hybrid retriever that handles Kinds 1 and 2 together.

**Kind 3: "Show me how these things connect."** This is the one that breaks RAG systems in demos. The user wants structure. "Which justices tend to vote together on civil rights cases?" "What upstream services depend on the auth service?" "Who reports to the VP of Engineering?" The answer isn't hiding in a document somewhere. The answer lives in the edges between entities. You can't find it by similarity, and you can't find it by keyword, because it was never written down as text in the first place. You need a graph. Apache AGE lets you run Cypher inside Postgres and do multi-hop pattern matches without bolting on another database.

Now the part that took me longer to accept than it should have. Kinds 1 and 2 are the 80% case. On most real RAG workloads, vector+BM25 is doing most of the work, and it's doing it well. Kind 3 is the 20% case. The art isn't running all three retrievers on every query and praying the ranker figures it out. The art is knowing which shape the user is asking and applying graph only when graph is the thing that helps.

## The honest numbers from our benchmarks

I ran the same question set through four different retrieval configurations on the SCOTUS dataset, because I didn't trust my own instincts and I wanted the spreadsheet to tell me what was actually true. Here's what fell out.

Vector plus BM25, by itself, scored somewhere between 75% and 90% accuracy on the bulk of the questions. Not 40%. Not "needs graph to work." Seventy-five to ninety, right out of the box, on the first retrieval pass, with no graph in the picture at all. That was the first number that surprised me.

Graph, layered on top correctly, added another 1% to 5% on the questions that needed multi-hop reasoning. That's real, and on the right question it's the difference between a right answer and a wrong one, but it's not the 40-point swing I was half-expecting before I started measuring.

And here's the part I didn't want to publish. Graph SUBTRACTED 2% to 4% when I misapplied it. When I treated graph as a co-equal retriever and merged its results into the ranker for questions that didn't need a graph at all, the graph hits diluted the ranking and pushed the actually-correct vector hits down the list. Graph isn't free. It's a cost you pay to get better answers on a specific kind of question, and if you apply it to the wrong question, you pay the cost and get worse answers.

So the honest framing isn't "use all the retrievers and let the ranker sort it out." The honest framing is: vector+BM25 is your floor. Graph is a multiplier you apply when the query shape earns it. Anywhere else, you keep graph out of the ranking path entirely.

## The 3-stage architecture that actually works

Once I had those numbers, the architecture rewrote itself. Here's the shape I'd build if I were doing this for real today.

```
Query
  │
  ▼
Stage 1: Vector + BM25   (ALWAYS, ~20-30ms)
  │  Top-K chunks by semantic + keyword relevance.
  │
  ▼
Stage 2: Graph Boost     (CHEAP, +~10ms)
  │  For entities mentioned in the top-K chunks,
  │  look up 1-hop neighbors and re-rank.
  │  Chunks that mention a neighbor get a 1.2x score bump.
  │
  ▼
Stage 3: Graph Expand    (EXPENSIVE, CONDITIONAL, +30-60ms)
  │  Only fires when:
  │    - user explicitly asks for expand mode
  │    - top-K vector scores are all weak
  │    - query matches a graph-shaped pattern
  │      ("who voted with", "what depends on", "who owns")
  │
  ▼
Return
```

Stage 1 carries most of the load, and it runs on every single query. Your fast path stays fast, roughly 30 milliseconds, because vector+BM25 was already fast and you haven't bolted anything heavy onto it. That's the foundation. Everything else is bonus.

Stage 2 is the sneaky one. Instead of treating graph as a competing retriever with its own ranked list to merge in, you use it to nudge the vector ranking you already have. Grab the entities mentioned in the top-K chunks, look up their 1-hop neighbors, bump any chunk that mentions a neighbor by a 1.2x score multiplier. That's it. Small enough to never ruin a good answer, big enough to rescue a borderline one, and cheap enough (about 10ms) that you can leave it running on every query and forget about it.

And then there's Stage 3, which mostly doesn't run. When the user asks a question with an obvious graph shape ("who voted with," "what depends on," "who owns"), or when your top-K vector scores all come back weak, you pay the extra 30 to 60 milliseconds to run a proper multi-hop Cypher query. When they ask "what is Chevron deference," you don't. That conditional is the whole point. Graph retrieval is expensive only when you make it expensive on every query.

The win from this arrangement isn't raw peak accuracy. It's that graph stops being able to hurt you. Your worst case on a pure-semantic question is still vector+BM25, which was already 75% to 90% accurate. You never ship an answer that got worse because the ranker was confused. That's the floor nobody talks about.

## Why most teams only build one

Let's be honest about why this happens. Vector search is easy. There's a tutorial for it on every blog, including probably one I wrote. Hybrid search is a little harder, but it's well-documented and every Postgres shop already has `tsvector` in their back pocket whether they know it or not. Graph databases, though, feel foreign. They get dismissed with, "we don't need another database to babysit."

I get it. I was that guy. For years I pushed back hard on adding more datastores to production stacks, because I've watched teams drown in their own infra choices. One Postgres cluster with backups and monitoring is a known problem. Three different datastores with three different failure modes is a new job.

Here's what I missed. You don't actually need another database. Apache AGE is a Postgres extension. pgvector is a Postgres extension. Full-text search is built in. You can run all three retrieval paths inside one Postgres 16 instance, with one backup job, one monitoring dashboard, and one on-call pager. I spent years telling people not to add more databases, and then I sat down to build this demo and realized the thing I was most worried about (running AGE and pgvector in the same cluster) was the easy part. The hard part, as always, was figuring out which retrieval technique to use when. Data engineering, not database selection. I guess I'm consistent if nothing else.

## When each technique wins, and when it falls on its face

Abstract arguments are fine, but let me show you three real queries from the SCOTUS demo we built, because it makes the split obvious.

**Query 1: "Find cases about administrative overreach."** Vector search crushes this. The phrase "administrative overreach" probably isn't in the opinions verbatim, but the concepts ("arbitrary and capricious," "Chevron deference," "agency action") live in the same semantic neighborhood. A cosine similarity search over a pgvector index returns the right cases on the first try. Hybrid adds a little precision. Graph is basically useless here, because the answer isn't about which entities are connected, it's about what the documents mean. Vector-only is good enough, and you'd be wasting compute running the other paths.

```sql
SELECT case_name, 1 - (embedding <=> query_embedding) AS similarity
FROM cases
ORDER BY embedding <=> query_embedding
LIMIT 10;
```

**Query 2: "Find the case with docket number 17-204."** Now vector fails. `17-204` doesn't carry meaningful embedding signal, and the model compresses it into something close to the general idea of "numbers in a legal document." You'll get a bunch of cases that mention docket numbers, just not the one you asked for. Hybrid search saves you here, because `tsquery` matches the exact token and ranks it first. This is a one-line win, and it's the reason I still tell people to turn on full-text search even when they think they don't need it.

**Query 3: "Which cases did Justice Thomas and Justice Sotomayor vote together on?"** This is the query shape where Stage 3 triggers. Two named entities, an implicit relationship between them, and a question that wants the intersection rather than the union. Vector search returns documents that talk about voting. Hybrid search returns documents that mention both names. Neither actually answers the question, because the answer isn't in any single document. It lives in the edges between Justice nodes and Case nodes in the graph. One Cypher query does what vector and hybrid cannot do at any cost:

```cypher
MATCH (j1:Justice {name: 'Clarence Thomas'})-[:VOTED_MAJORITY]->(c:Case)
      <-[:VOTED_MAJORITY]-(j2:Justice {name: 'Sonia Sotomayor'})
RETURN c.case_name, c.decided
ORDER BY c.decided DESC;
```

That's a multi-hop pattern match across typed edges. Vector and hybrid cannot express this query, period. Not slowly, not with clever prompting, not at all. If a non-trivial fraction of your users' questions look like this, Stage 3 is worth building. If almost none of them do, you can skip it and live on Stages 1 and 2 and be completely fine.

## How we built the demo

The stack is deliberately boring, which is the point. Postgres 16 with pgvector and Apache AGE, both built from source and baked into one image. A FastAPI orchestrator that runs all four retrieval paths in parallel (vector only, hybrid, graph only, and a combined path that merges them with reranking). A side-by-side UI that shows exactly what each approach returns for the same question, so you can see the split with your own eyes instead of taking my word for it. One Postgres cluster. One ops footprint. No hand-waving.

The dataset is real. 391 Supreme Court cases from 2018 through 2023, with justice votes, majority opinions, dissents, and citations modeled as graph edges. We also ship a synthetic Acme Labs org knowledge base example for people who want to see the same pattern on corporate-style data without the legal vocabulary. Both run on the same stack, and both make the three-question split painfully obvious. The repo is public. Pull it, run it, and ask it the questions your users actually ask you.

One thing I want to be honest about. The demo app runs all four strategies in parallel on purpose, and it's not because I think you should do that in production. It's because the whole point of a comparison tool is showing what each retriever returns in isolation, side by side, for the same question. If I routed every query to "the right" path, you'd never see the difference, and you'd have to take my word for which approach won. I'd rather show the tape. For a production system, you want the 3-stage setup from earlier in this post, where vector+BM25 is always on, graph boost is cheap and ambient, and graph expand is conditional on the query shape. The demo is a teaching tool. Don't ship the teaching tool as the product.

## What's coming in Parts 2 and 3

Part 2 is the setup guide. How to build Postgres 16 with AGE and pgvector from source (because the packaged builds don't always line up), how to bring up the Docker Compose stack, and how to run your first Cypher query and your first vector query to prove the thing is alive. It's the "I just want to get this running on my laptop before lunch" post.

Part 3 is the replication walkthrough. How we built the SCOTUS parser, how we designed the graph schema (justices, cases, votes, citations, and the tradeoffs in each), how we added multi-hop query detection so the orchestrator knows when to reach for Cypher, and how to adapt the whole thing to your own dataset. If you want to build your own GraphRAG system on top of this pattern, Part 3 is the one to bookmark.

## Your homework

Go figure out what fraction of your users' questions actually need graph. Pull a week of query logs, or a day if that's all you have, and bucket them. How many are "find me something like this"? How many are "find me exactly this"? How many are "show me how these things connect"? That ratio is the thing that drives your architecture, and you can't guess it from your gut.

If the relationship questions are a sliver, your architecture should treat graph as optional. Vector+BM25 is your floor, and you might only need Stages 1 and 2, and you can sleep at night. If the relationship questions are a serious chunk of the workload, you need first-class graph retrieval wired in as Stage 3, with real query-shape detection, real Cypher, and a Postgres with AGE sitting next to pgvector in the same cluster. And if you have no idea what the ratio is, that's the worst answer, because it means you're going to find out in production with a Slack thread full of angry users.

Me, I'll be over here running Cypher inside Postgres and pretending I always thought graphs were a good idea. Don't tell anyone I used to argue the other way.
