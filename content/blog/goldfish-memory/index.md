---
title: "Your Agent Has Goldfish Memory (And Your Vector Store Won't Fix It)"
date: 2026-05-24
draft: false
tags: ["chunkshop", "agent-memory", "rag", "postgres", "pgvector", "ai", "agents"]
summary: "Agent memory has two completely different jobs — fast context for the next reply, and curated truth three weeks later — and most people try to do both with one tool. Here's the two-tier pattern I built chunkshop's memory layer around, the late-event bug that silently eats conversations, and why 'just use pgvector' isn't the whole answer."
build:
  list: never
---

I've spent the last month watching agent-memory tools quietly fail.

Not blow-up fail. Not error-message fail. The worse kind: shipped, in production, technically running, and the agent acts like it's never met you before. Or — sometimes more annoyingly — it remembers way too much from three weeks ago and trips over outdated context.

You ask a coding assistant about your Postgres schema on Monday. Tuesday you ask it again. It has no idea you talked yesterday. The fix is "just use pgvector" or "plug in mem0" or "spin up Zep." And those tools are real, they work, they're not bad. But they're not the *whole* problem.

The whole problem is that agent memory has two completely different jobs and most people are trying to do them with one tool.

Let me unpack that.

## The two jobs

**Job one: the next reply needs context fast.**

User just said something. Twelve seconds from now they want a coherent response that acknowledges what they said two messages ago. The memory layer's job here is freshness. Latency. Cheap. Doesn't matter if it's perfectly structured — it matters that *something* relevant comes back in under 100ms.

**Job two: the agent should still know you in three weeks.**

Different ballgame. Three weeks from now you'll have had 200 turns of conversation, half of which are obsolete (you switched databases, you abandoned the side project, you changed your mind about microservices — twice). The memory layer's job here is *good*: what's still true, what's been contradicted, what was an experiment, what's the actual through-line.

These are not the same problem. Job one wants speed. Job two wants quality. If you try to do both in one pass, you get a bad version of both. The realtime path is either too slow or too shallow, and the long-term path either falls behind or eats your compute budget on context you're going to throw away.

This is what I built chunkshop's memory layer around. Two tiers. One pattern.

## Realtime vs consolidate

The realtime tier writes provisional rows. Every minute. Cheap chunker, no segmentation, no fact extraction. Just: take whatever turns came in since the last tick, embed them with a small fast model (we ship int8 BGE-small by default — 384 dimensions, runs in milliseconds), drop them in Postgres with `tier='provisional'`. Done.

A fresh agent reply runs against that table and finds the user's last twelve turns in vector + tier='provisional' filter. Total memory hit: under a second. Total cost: pennies.

The consolidate tier runs nightly. Or hourly. Or whatever your data shape needs. Slower. Smarter. It segments sessions into *episodes* — natural conversation chunks based on time gaps, turn counts, when the topic actually shifted. Then it calls a *consolidator* — you wire this — to extract structured facts. Subject-predicate-object triples. Things like `queue uses redis` becoming `queue uses postgres` six weeks later.

And then — this is the part that took me three iterations to get right — the consolidate run **supersedes** the provisional rows. Drops them. Replaces them with `tier='consolidated'`. Now when your agent reads, it sees the curated long-term version, not the raw turn-by-turn version.

When both tiers exist for the same session, the reader picks consolidated. We call this rule O2. Skip it and your agent will see double, recall conflicting things, and tell you Redis is the queue when you migrated to Postgres last month.

## The bug I almost shipped

I want to walk through one mistake because it makes the design concrete.

My first implementation of the consolidate cell filtered the staging table at **row** granularity. New events since the last consolidate run got selected. Sensible, right? That's how every incremental ingest pattern works.

Wrong, in this case. Here's what happens:

1. Day 1: user has a five-turn conversation. Consolidate runs that night. Five rows in `chunkshop_staging` get marked consumed. The session gets a clean consolidated episode in `agent_memory.memory`.
2. Day 8: user follows up — one new turn. "Hey, about that thing we talked about last week..."
3. That night, consolidate runs. The row-level WHERE picks up the ONE new event. The session gets re-emitted with only that fragment. The chunker emits an episode chunk from one line of text. The MemorySink's destructive supersede DELETEs the prior consolidated rows and replaces them with the fragment.

The agent forgets the entire prior conversation. Every. Single. Time. The user mentions it.

This is the kind of bug that doesn't crash. It doesn't log an error. Your tests pass. Your users just slowly stop trusting the agent.

The fix is that the consolidate WHERE has to operate at **session** level. When any event for a session is unconsolidated, the whole session is re-emitted, the supersede builds a fresh consolidated version with the full conversation history, including the new turn. The bug was structural — row-level was the wrong unit.

I caught this because the spec called for a test of the exact scenario, and I made myself write the test before I called it done. That's the test that turned red. The bug had already shipped to my own machine and I'd been using it. The test was the only thing standing between that and a real deployment.

I keep telling people: the spec-first thing isn't ceremony. It's how you find the load-bearing bugs before your users do.

## Why "just use pgvector" doesn't work

When I describe the two-tier pattern, the obvious question is: why isn't this just `SELECT * FROM embeddings WHERE session_id = $1 ORDER BY embedding <-> $2 LIMIT 10`?

Because that query doesn't know about:

- Whether two rows belong to the *same conversation* but contradict each other.
- Whether one row has been *replaced* by a later turn.
- Whether a fact has been explicitly retracted.
- Which row is *consolidated* and which is *provisional* fragment that should be hidden.

You can layer all of that in your application code. People do. The result is usually:

- A `metadata` filter the application has to manage.
- A `WHERE retracted = false AND tier = 'consolidated' AND effective_to IS NULL OR effective_to > now()` that nobody can maintain six months later.
- A homegrown supersede mechanism that doesn't quite get cross-namespace isolation right.
- And eventually, a custom thing that looks suspiciously like the chunkshop memory schema, except undocumented.

I built chunkshop's memory layer because I was tired of writing this code in three different agent projects. The pattern was the same every time. I might as well factor it out.

## The consolidator is the seam

One thing I want to flag: chunkshop ships a zero-network extractive consolidator by default. It picks sentences for an episode summary. It does *not* extract structured facts. That requires a real LLM (or a rules engine, or whatever you're brave enough to use).

This is intentional. Fact extraction is the part where you make tradeoffs — which model, which prompts, how strict on confidence, how to handle multi-hop reasoning. I'm not going to make those choices for you. The consolidator is a *seam* — Python lets you point at a callable in your YAML, Rust lets you implement a trait. You bring the brain, chunkshop handles the choreography.

The default is enough to validate the pipeline works end-to-end. You'll know you need a real consolidator the first time you read `kind='fact'` rows and they all have NULL subject/predicate/object columns. That's the extractive default telling you it's not its job.

## What this means for what you build

Three takes from a guy who's now done this in two languages and shipped it.

**First**: agent memory isn't a database problem. It's a *scheduling* problem on top of a database. The database part is easy. Postgres with pgvector solves it. The scheduling part — when do you write fresh vs curated, when do you supersede, how do you handle late events — that's where the architecture lives.

**Second**: don't build your own. (I know, I know, says the guy who built one.) But if you're going to build one, make sure you handle the late-event case. Write the test before you write the WHERE. Stage events, consolidate, stage a late event, consolidate again, and assert the agent still remembers the original conversation. Most home-grown memory layers fail that test silently.

**Third**: if you're using an existing memory tool (mem0, Zep, Letta, whatever) and it's working — great, ship it, move on. The point of chunkshop's memory layer isn't to replace those. It's the layer underneath. You can absolutely use chunkshop as the *write* side and your tool of choice as the *read* side. They compose.

The whole reason I built this is so I didn't have to think about agent memory again. I just want it to work, in the background, on a schedule, with a small enough operational footprint that I can forget about it for weeks at a time.

Which — come to think of it — is exactly what we want our agents to do for us.

---

*chunkshop's agent-memory layer ships in v0.4.4 (Python) and via the `memory` feature in chunkshop-rs (Rust, just merged to main, will tag soon). [Repo on GitHub.](https://github.com/yonk-labs/chunkshop) The architectural write-up lives in [docs/architecture/memory-sink.md](https://github.com/yonk-labs/chunkshop/blob/main/docs/architecture/memory-sink.md) if you want the details. Tutorial post on wiring this into your own agent — that's a separate post, coming next.*
