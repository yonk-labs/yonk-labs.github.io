---
title: "I keep picking the wrong chunker. Bakeoff fixed it."
date: 2026-05-08
draft: false
tags: ["chunkshop", "pg-raggraph", "rag", "chunking", "embeddings", "benchmarking", "postgres"]
summary: "Three corpora, three different winners, none of them the chunker the README recommended. Why nobody can tell you in advance which chunker to use, and the 30-minute primitive that does the work for you."
build:
  list: never
---

Look. I've been picking chunkers by reputation for the last 18 months. I read what other people recommend, what the README says is the "production sweet spot," what worked on the corpus the library was tuned against. I run with that. Move on. Build the rest of the pipeline.

I was wrong on three corpora in a row.

Three different shapes of data, three different bakeoff results, three different winners. Not one of them was the chunker I would have picked from the README. The one corpus where "chunkshop's recommended hierarchy chunker" actually won was the one I would have guessed wrong on.

So let's talk about what actually wins, why nobody can tell you in advance, and the tool that does the work for you.

## The hot take, up front

There is no best chunker. There is no best embedder. There is no universal default that survives contact with a real corpus. I know this isn't a new insight in 2026 (the academic literature has been saying it forever), but it keeps not landing in production code because we're all still picking chunkers like we pick a Linux distro — by reading some smart person's blog post and going "yeah, that one." (Including this one. Don't pick a chunker because of this post.)

Here's what changed my mind.

I've been working on [pg-raggraph](https://github.com/yonk-labs/pg_raggraph), a postgres-native GraphRAG library. It pairs naturally with [chunkshop](https://github.com/yonk-labs/chunkshop), which is a sibling library specifically for the chunking + embedding + extraction step of an ingest pipeline. Chunkshop is the dedicated tool. It ships seven chunker strategies. Its README has a "production sweet spot" recommendation: hierarchy chunker plus int8-quantized bge-small. Tuned across multiple bake-off corpora. I trusted it.

So when I integrated chunkshop into pg-raggraph, the first thing I did was wire `chunk_strategy="chunkshop:hierarchy"` as the recommended path. Wrote a cookbook. Ran the example. Counted the entities and relationships in the resulting graph.

Looked great. 31% more relationships than the built-in chunker. Fewer chunks, denser graph, more LLM context per extraction call. Story written.

Then I checked the actual answers.

## The check I almost skipped

Before shipping the recommendation I ran a per-mode comparison. Five questions, six retrieval modes, OpenAI judging on a 0-3 rubric. Boring sanity check.

```
                              global  smart
Pattern A (built-in)           3.00   3.00
Pattern D (chunkshop:hier)     2.00   2.20
```

**The denser graph scored worse.** Specifically `global` mode, which is the relationship-centric path that should benefit most from a richer graph, dropped a full point. I sat with that for a few minutes. I almost talked myself out of it ("n=5, that's just noise"). But the regression was consistent across two of the most graph-dependent retrieval paths, and "more edges in the graph = better answers" is the kind of intuition you should be skeptical of when the data says otherwise.

(I have a kid. I know what it looks like when you really really want something to be true. I was doing it.)

So when somebody pushed back with "well chunk shop with a higher dimension model and the right chunking strategy should perform better, look into it," that was the right pushback. I'd been comparing one chunker to another. The actual question is bigger: chunker AND embedder AND quantization AND corpus shape. Four axes. You can't pick by intuition.

## Bakeoff is the right primitive

This is the part I want database engineers to take away from this post. Chunkshop ships a `bakeoff` subcommand. It's not a research tool. It's not "advanced." It's the basic primitive that should run before you commit to a chunker.

You give it three things. A corpus (any source — files, a postgres table, http endpoint, S3, JSON corpus). 8-15 gold queries — pairs of (question, doc-id-that-should-be-top-1). And a matrix: list of embedders, list of chunkers. It takes the cross-product, ingests each combo into its own pgvector table, runs every gold query through every combo, computes Recall@1/3/5 plus MRR per combo, and emits a leaderboard plus a `recommended.yaml` ready to plug in.

Total time on a small corpus: 5-10 minutes wall clock, no LLM calls (it's pure embedding + pgvector recall, costs nothing). On a 1700-doc corpus: 10-15 minutes. The cost of running bakeoff is roughly the cost of pretending you don't need to.

I built three configs. PG docs (31 markdown files, the kind of corpus where I actually do my work). Sales call notes (649 short narrative documents, ~280 chars each, very different shape). MuSiQue (1700 Wikipedia paragraphs, multi-hop QA dataset, dense factual content). Same matrix on each: 3 embedders × 3 chunkers = 9 combos.

Then I read three leaderboards. They didn't agree.

## What actually won

**Postgres docs** (31 well-structured technical docs, gold queries like "How do I configure HNSW vector indexes for pgvector?"):

| Rank | Chunker | Embedder | r@1 | MRR |
|---|---|---|---|---|
| 1 | **fixed_overlap** | bge-base **int8** | 0.90 | **0.95** |
| 2 | fixed_overlap | bge-base fp32 | 0.90 | 0.93 |
| 3 | hierarchy | bge-base int8 | 0.90 | 0.93 |

Top three are basically tied at MRR 0.93-0.95. Doesn't matter much. Pick one and ship.

**Sales call notes** (649 short narrative docs):

| Rank | Chunker | Embedder | r@1 | MRR |
|---|---|---|---|---|
| 1 | **fixed_overlap** | bge-base **fp32** | 0.40 | **0.53** |
| 2 | fixed_overlap | bge-small | 0.40 | 0.51 |
| 3 | fixed_overlap | bge-base int8 | 0.30 | 0.48 |
| ... | hierarchy | various | 0.20 | 0.33 |

Hierarchy is rank 4-5 here. Fixed_overlap dominates the top three.

**MuSiQue** (1700 Wikipedia paragraphs):

| Rank | Chunker | Embedder | r@1 | MRR |
|---|---|---|---|---|
| 1 | **hierarchy** | bge-base **int8** | 0.40 | **0.43** |
| 2 | hierarchy | bge-base fp32 | 0.40 | 0.42 |
| 3 | hierarchy | bge-small | 0.30 | 0.38 |
| 4 | sentence_aware / fixed_overlap | various | 0.30 | 0.33-0.35 |

Hierarchy dominates top three here. Fixed_overlap is rank 5+ — exactly the chunker that won on the other two corpora.

So look at this. Fixed_overlap wins on two out of three. Hierarchy wins on the third. Same matrix. Same tool. The chunkers traded places. The embedder family is consistent (bge-base over bge-small) but the *quantization* sign flips: int8 wins on PG docs and MuSiQue, fp32 wins on sales notes. Same model, two different quantizations, opposite sign of the effect across corpora.

## Why this happens (the hand-wavy theory)

Here's what I think is going on. I'd love to claim I tested this rigorously. I didn't. This is a corpus-shape pattern-match.

Three things I noticed:
1. **Hierarchy chunker bundles aggressively.** It looks for `# Heading` boundaries and packs the section body into one chunk. On long structured documents (Wikipedia paragraphs, MuSiQue) it preserves topical coherence. On short narrative documents (sales call notes) it collapses each whole note into one chunk and you lose the ability to distinguish which note is which.
2. **Fixed_overlap slices straight through structure.** Uses overlapping word windows. On well-structured technical docs (PG docs) it produces multiple focused fragments per doc and recall@1 is great. On narrative content where the sentence is the meaningful unit, it works because each window is roughly one paragraph of focus.
3. **Quantization is corpus-dependent.** I genuinely don't have a good story here. int8 won on PG docs and MuSiQue and lost on sales notes. The quantization noise interacts with whatever else is going on per corpus.

The pragmatic takeaway is that chunker choice tracks corpus shape, not chunker reputation. Wikipedia-shaped content rewards hierarchy. Technical docs reward fixed_overlap. Narrative call notes reward fixed_overlap. The "right" chunker is the one that respects what your corpus actually looks like, not the one that won on the corpus the library author had in front of them.

I am not going to write a heuristic for this. Every heuristic I write would be wrong on a fourth corpus. Run the tool.

## Cost of the exercise

Let's be honest about what this actually took. Authoring 10 gold queries per corpus: 20 minutes of skimming the source data and picking distinctive lookups. Writing the YAML configs: 10 minutes. Running the three bakeoffs: 25 minutes total wall time (no LLM calls, no API costs). Reading the leaderboards: 5 minutes.

Compare that to my actual previous workflow. Pick a chunker by reputation. Ingest the full corpus through pg-raggraph (~70 minutes per corpus, plus $0.30 in LLM extraction). Run a per-mode Q&A comparison (~10 minutes plus another $0.20 in LLM judging). Get a confusing result. Try a different chunker. Re-ingest. Re-judge. The loop is hours per iteration with real LLM costs.

Bakeoff is the right primitive specifically because it isolates the chunker-vs-embedder choice from everything else. After bakeoff picks a winner, you can layer the LLM extraction, graph traversal, smart routing, reranking, all of that on top — knowing the foundation isn't sagging. The thing I was doing wrong for 18 months is tuning higher layers while the foundation was wrong.

## What I'm telling people now

Three things, because everything comes in threes.

First. Bakeoff before you commit. The minimum viable matrix is two embedders times three chunkers. That's six combos and it'll tell you 80% of what you need. Authoring 8-10 gold queries takes 20 minutes — pick distinctive documents and write queries that should single each one out. The whole exercise is 30-45 minutes total. There is no version of "just pick a chunker by feel" that's faster than running the tool.

Second. Don't trust me. Don't trust the chunkshop README. Don't trust the bge-base int8 default. Don't trust any "best chunker" recommendation in any blog post about chunking — including the one you're reading. Universal recommendations are wrong on at least one of the three corpora I tested, and yours might be a fourth shape that breaks all of them.

Third. The data engineering layer is where most RAG performance is hiding. We talk about model selection. We talk about retrieval modes. We talk about reranking. The chunker is upstream of all of that, and it controls what's even possible to retrieve. A wrong chunker upstream means no amount of clever downstream tuning saves you. Get the foundation right first.

The bakeoff configs from this post live in the [pg-raggraph repo](https://github.com/yonk-labs/pg_raggraph) under `docs/cookbook/samples/chunkshop-bakeoff-*.yaml`. Three configs, three corpora, three different shapes of data. Drop them on a copy of your corpus and you'll have your own answer in 15 minutes.

Now the real question — is your current chunker the one that wins your bakeoff, or the one you picked because somebody on the internet said it was the production sweet spot?
