---
title: "We Gave Agent Memory Semantic Search. It Still Lost to Boring Old RAG."
date: 2026-06-04
draft: false
tags: ["agent-memory", "vector-search", "pgvector", "rag", "postgres"]
summary: "We added semantic search to agent memory, then benchmarked it against plain document RAG on the same questions. The boring baseline won by 6x. Here is why that is the point."
build:
  list: never
---

I will save you the suspense. We built semantic search into our agent memory layer, ran it head to head against plain old document retrieval, and the plain old thing won. Not by a hair. On a conversational-memory benchmark, recalling from the memory store scored 0.10. Retrieving from the raw documents on the same questions scored 0.65 to 0.83.

That is our shiny new feature losing to the baseline it was supposed to one-up, by roughly 6x. And it is the most useful number I have generated in weeks.

I have spent twenty years around databases, and the single most expensive habit I see is teams shipping the thing they hoped was true instead of measuring the thing that is. So before this becomes one more breathless "agent memory changes everything" post, here is the measurement, sample size attached, including the part where we lose.

## TL;DR (and why you should keep reading)

- Everyone already knows vector search beats keyword search on paraphrased queries. We confirmed it (vector recall 0.10 versus keyword 0.025). That was never the interesting question, and a demo built around it is a solved problem wearing a breakthrough costume.
- The interesting question: does a memory store beat the document RAG you already run? We tested it on the same questions with the same judge. Memory lost, badly, at single-doc question answering.
- That is not memory being useless. It is memory being used as the wrong tool. Recall a pile of fragments and you have built a slower, worse retriever.
- Memory earns its keep on what RAG structurally cannot do: carrying context across sessions, gauging its own confidence, storing the action to take, flagging a fact once it goes stale. Those are the next posts in this series.
- Semantic recall made memory findable by meaning. Findability turned out not to be the gap. Keep reading for the numbers and the real gap.

If anyone is about to rip out RAG and replace it with "agent memory," I have a benchmark that might save you a quarter.

## The captain-obvious part, so we can move past it

Keyword search, which in Postgres means `tsvector` and friends, is fast, cheap, and literal. It nails the query when the words overlap and goes stone blind the moment a user rephrases. Store "rebalancing across restarts," ask about "reshuffling on deploy," and keyword recall returns nothing while the fact sits one row away.

Vector search fixes exactly that. So yes, when I gave memory a `pgvector` leg, paraphrase recall improved: 0.10 for vector against 0.025 for keyword. Four times better.

Hold the applause. "Semantic search beats keyword search" is not a finding, it is a premise. It has been true since before half the people selling it could spell HNSW. If a vendor's big memory demo is "watch it find the rephrase," they are showing you homework, not research. The real question is two levels up.

## The part that actually stung

Here is the deal: I did not just compare memory recall against itself. I pointed it at the same conversational-memory benchmark we use for document retrieval (LoCoMo, n=40, same judge model), and I let the memory store fight the document-RAG pipeline on identical questions.

Memory recall, best case, scored 0.10. The document-RAG lanes scored 0.65 to 0.73, and just feeding the model the whole conversation hit 0.83. Same questions. Same grader. The memory store got beaten by 6x to 8x by the unglamorous approach we already had running.

So what does that actually mean? It means a memory store full of raw conversation fragments is a bad retriever, and I have [the receipts](https://github.com/yonk-labs/stele/blob/main/testing/results/MEGA-GRID.md). The answer to a LoCoMo question is usually stitched together across several turns. Document RAG hands the model big, contiguous, neighbor-expanded chunks, so the context hangs together. My memory store handed it a shredded pile of one-liners and asked it to reassemble the thought. The model did about as well as you would, which is to say badly.

Now the honesty tax, because I am not going to pretend my benchmark was a masterpiece. That result indicts how I filled the memory store as much as anything. I dumped sentence fragments in and recalled them. A real memory pipeline extracts and consolidates facts instead of shredding the source. But that is the whole lesson, not a loophole: "memory" is not "RAG with extra steps." Use it as a drop-in retriever and you will build a worse retriever, and a benchmark will tell you so in an afternoon.

## What we actually changed, and why it was still worth doing

The change itself is small and, on its own merits, fine. On Postgres you can flip on a vector embedding for each memory, stored next to the text, and recall fuses two legs with reciprocal rank fusion: the keyword leg for precision, the vector leg for paraphrase, ranks combined so neither one wins alone. It is off by default, so existing recall is unchanged to the byte. The embedder wires itself up from the model your index already loads, so there is nothing new to configure and no second vector database to babysit.

But I want to be precise about what this bought us, because the temptation is to oversell it. Semantic recall made memory *findable by meaning*. That is necessary plumbing. It is not the payoff. You cannot get value out of evidence-weighting or structured insight or lifecycle tracking if you cannot find the memory in the first place. We built the findability. Findability does not beat RAG. The features riding on top of it are the actual bet, and they are coming.

One more thing the benchmark did for me, free of charge: the very first time it wired up the real embedding model, the vector path face-planted before it answered a single question. We had shipped it with a unit test using a fake embedder that returned a tidy list of floats. The real model returns a numpy array shaped a little differently, and the code building the database vector choked instantly. The benchmark caught it in the time it takes to pour coffee, and we had a fix in within the hour. That is the entire argument for benchmarking your own work. It embarrasses you in private on a Tuesday instead of in front of users on a Friday.

## The results, with the sample size bolted on

Two findings, stated plainly.

**Turning all of this on changed nothing about document retrieval.** The RAG lanes landed within a single question of their prior numbers (0.825, 0.725, 0.675, 0.650 on LoCoMo across the lanes I reran). Additive means additive: new capability, old guarantees intact, no asterisk.

**Memory recall, as a RAG replacement, lost.** At n=40 (not the n=10 hand-wave from an early smoke run, an actual forty questions), keyword recall scored 0.025 and vector recall 0.10, against 0.65-plus for document RAG on the same set. This one is a verdict, not a whisper. The caveat stands: naive population, raw fragments, no extraction. Fix that and the gap narrows. The point survives anyway, which is that memory is not a better mousetrap for single-document QA, and you should stop expecting it to be.

## How you can try it (and how not to fool yourself)

You need Postgres for the semantic part. The rest of the memory layer ([stele](https://github.com/yonk-labs/stele)) runs on plain SQLite.

Turning on hybrid memory recall is one config key:

```python
from stele import Stele
from stele.core.memory_record import MemoryScope

stele = Stele.from_config({
    "backend": {"type": "postgres", "dsn": "postgresql://.../db"},
    "retrieval": {"memory_vector": True},   # off by default; Postgres-only
})

print(stele.capabilities().memory_vector_search)   # True
```

Recall is the same call it always was. The fusion happens underneath:

```python
scope = MemoryScope(user_id="alice")
hits = stele.memory.search_with_score("reshuffling on deploy", scope, limit=10)
# a memory stored as "rebalancing across restarts" now surfaces
```

My challenge to you is the cheapest insurance you will buy this year. Before you replace your retrieval stack with "agent memory," point both at the same questions and the same judge and let them fight. If memory loses, you found out for the price of an afternoon instead of a roadmap.

Memory recall on its own lost to RAG. That is not the end of this story, it is the opening scene. The bet is not memory-as-retriever. It is memory that knows how sure it is, what to do about a fact, and when that fact has gone stale, all of it working together. The next post is about what a memory even is on the way in, before you ever try to recall it. Until then, go make your own memory layer fight your own RAG, and do not trust anyone who only shows you the rephrase demo.

