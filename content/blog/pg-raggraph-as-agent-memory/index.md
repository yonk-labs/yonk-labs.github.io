---
title: "Your agent forgets things. pg-raggraph might be how you fix that."
date: 2026-05-12
draft: false
tags: ["pg-raggraph", "agent-memory", "rag", "graphrag", "postgres", "ai", "agents"]
summary: "Modern AI agents need three different kinds of memory and only one of them is RAG. The episodic, relational, time-anchored kind needs a graph — and pg-raggraph happens to be shaped exactly right. Tier 1 evolution awareness, retraction-aware retrieval, namespace isolation. What's built, what's still gap."
build:
  list: never
---

Every coding agent I've used in 2026 has the same problem. It doesn't remember anything I told it last week. Or last hour. Each session starts cold. Every onboarding question gets re-asked. Every "no, we tried that, it didn't work" gets re-discovered. The most expensive thing in a typical agent loop is the human re-explaining context the agent should already have.

I've been thinking about this through the lens of pg-raggraph for the last few months, and I'm increasingly convinced that "agent memory" is the workload pg-raggraph was actually built for — even though the project framing has been GraphRAG-on-postgres up to now. Let me walk through why.

## What "agent memory" actually means in practice

Strip away the marketing for a second. Modern AI agents need to remember three different categories of stuff, and they are *not* the same problem.

**Conversational state.** The user said X, you replied Y, the user clarified Z. This belongs in a turn-buffer or a session log. Last 10-50 turns, FIFO eviction. Mature solutions exist (LangGraph checkpoints, Mem0's session memory, half a dozen others). pg-raggraph isn't trying to compete here — this is fine in a JSONB column on a sessions table.

**Factual recall over a corpus.** The agent should know what's in the codebase, what the on-call runbook says, what the team's documented conventions are, what last quarter's architectural decisions were. This is regular RAG. Vector retrieval over chunks. pg-raggraph handles this, but so does any reasonable RAG library. Nothing special required.

**Relational/episodic memory.** The agent worked on issue #1247 last Tuesday with developer A. That issue blocked deployment of service B because of a dependency on service C, which was owned by team D, who had paged about it the week before. When the agent picks up issue #1248 today, that whole chain — issue → developer → service → team → prior incident — should be retrievable. Not as a vector match. As a *graph*.

That third category is where current agent-memory tooling falls down. Vector-only memory can find "the chunk where service C was discussed," but it can't traverse the chain from "today's issue" to "last week's similar incident" through three shared entities. You need the relationship layer.

This is exactly the workload pg-raggraph was designed for. The graph isn't ornament; it's the retrieval primitive that lets the agent walk from "this current task" to "everything we already learned about it." Vector similarity gets you to the right neighborhood; the graph gets you across documents.

## Why pg-raggraph fits agent memory specifically

Three things matter for agent memory that aren't decorative requirements; they're load-bearing.

**Time travel.** Agent memory has a temporal dimension that document corpora don't. "What did the team think about service C *as of last Tuesday*?" is a real question. The architectural decision the agent should reference is the one that was current when the work happened, not the one we superseded yesterday. pg-raggraph's Tier 1 evolution awareness drops cleanly into this. Documents have `effective_from` and `retracted_at` columns. Retrieval takes an `as_of=...` kwarg. The same agent, same query, returns different memory depending on the timestamp it's anchored to. That's exactly the property a long-running agent needs.

**Retraction-aware retrieval.** When the agent learns "actually this approach didn't work, here's the new pattern," the old memory shouldn't be deleted (audit trail, future learning, "we tried that already" reasoning). It should be *retracted* — still queryable for "what did we used to think" but excluded from default retrieval. pg-raggraph has `retracted_behavior="hide"` / `"flag"` / `"surface_both"` exactly for this. The agent's memory becomes update-friendly without becoming forgetful.

**Per-tenant isolation via namespaces.** Multi-agent systems and multi-tenant-agent systems both need memory isolation. Agent A's session memory shouldn't bleed into Agent B's. Customer X's agent shouldn't see Customer Y's facts. pg-raggraph namespaces this end-to-end at the table level — every chunk, every entity, every relationship is namespace-scoped. The schema is shared (one set of tables), the data is partitioned. Backup, query, and audit semantics all stay clean.

## The architecture I'd actually build

Let me sketch the shape, because I think the abstract argument needs concrete grounding.

You have an agent. It does work — files changed, decisions made, errors hit, conversations with the user about what to do next. After each "task" (commit, conversation thread, ticket, whatever your unit is), an episodic-memory writer takes:

1. The task summary as a document.
2. The structured artifacts as caller-known entities and relationships — `(Developer)–[WORKED_ON]–(Issue)`, `(Issue)–[BLOCKED_BY]–(Service)`, `(Decision)–[OVERRIDES]–(PriorDecision)`. This is exactly what pg-raggraph's `ingest_records()` accepts as `entities=[...]` and `relationships=[...]` fields.
3. Metadata for filtering (`task_type`, `outcome`, `effective_from=task_completion_time`).

You feed those records into pg-raggraph. The library runs LLM extraction on the document text to find soft entities (people mentioned in passing, services referenced in error messages) on top of the structured FK-derived ones you brought. Now your agent's memory is a graph where:

- Hard FK relationships from your task tracker are pinned (the structured ones).
- Soft semantic relationships from the conversation text are extracted (the LLM-derived ones).
- Every fact has a timestamp via `effective_from`.
- Retraction is a first-class operation, not a delete.

At retrieval time, the agent calls `rag.ask(question, mode="smart", as_of=now)`. The router does aggregation-vs-lookup detection (recent improvement to the smart mode based on cross-corpus benchmarks), routes to the right retrieval path, returns chunks plus the entity/relationship neighborhoods. The agent gets context that includes "today's issue is similar to issue #1247 from last Tuesday, which was blocked by service C, which has the following architecture doc." All in a single retrieval call.

I think this is the actual long-term answer to "how do you give an LLM-driven agent durable memory." Not a bigger context window. Not a better summarizer. A relational memory layer with time-aware retrieval.

## What's already built vs what would still need work

I want to be honest about the gap between "the architecture fits" and "this is shippable as agent-memory infrastructure." There's still real work between today and that future.

**Already built and working:**
- The schema (documents, chunks, entities, relationships, plus provenance junction tables, plus Tier 1 evolution columns).
- `ingest_records()` API that takes `entities=[...]` and `relationships=[...]` for caller-known structure (this was a gap that landed two weeks ago — the API used to silently drop arbitrary metadata, and pinned FK relationships had to be backfilled via raw SQL).
- The six retrieval modes including smart-router with question-shape detection.
- Namespace isolation throughout.
- Time-travel retrieval via `as_of=...`.
- Retraction-aware retrieval via `retracted_behavior=...`.

**Real gaps for the agent-memory use case:**
- *Streaming ingest*. Agent memory wants ingest-as-you-go, not batch ingest. The current API is batch-shaped. Each task-completion-event would call `rag.ingest_records([one_record])`, which works but pays per-call overhead. A real agent-memory system would want a streaming write path with batching at the storage layer.
- *Forgetting policies*. Agent memory should fade. Old facts that haven't been retrieved in 6 months should be down-weighted, and very old facts beyond a tenant's retention window should be archived or deleted. pg-raggraph today doesn't have an out-of-the-box forgetting story. Tier 1 evolution gives you the *primitives* (effective_to, retracted), but the policy layer would need to be built.
- *Memory consolidation*. After 1000 tasks, you have 1000 small task documents. The agent's working set is "the recent 50 tasks plus the entity neighborhood of whatever I'm doing now." Periodic consolidation — summarize related tasks, merge near-duplicate entities, prune dead branches — isn't something pg-raggraph does. It would either need to be added as a maintenance pass or built externally.
- *Query latency at scale*. The benchmarks I've run are at 31-1700 documents. An agent memory store after a year of operation could be 50K-500K documents. The retrieval modes have HNSW + GIN + btree indexes, so this should be fine, but I haven't actually measured it at that scale yet. Don't trust performance claims I haven't run.

These are real gaps. I'm not going to pretend pg-raggraph is "ready for agent memory" today the way some libraries get marketed. The architecture fits the shape; the implementation needs another quarter of work focused specifically on the agent-memory access pattern.

## What I'm actually doing about this

The honest version: I'm watching how my own coding agent uses [`pgrg devmem`](https://github.com/yonk-labs/pg_raggraph) right now. It's a CLI wrapper around pg-raggraph that ingests a developer's notes and queries them as a knowledge base. Not full agent memory yet — it's a manual ingest from the developer side, not automatic from the agent side. But it's how I've been validating the access pattern.

What I'm seeing: the agent doesn't ask the same question twice in a session, but it asks the same question across sessions all the time. The memory layer needs to span sessions, span agents, and span machines. A local file isn't the right fit; a postgres database the agent connects to over the network is. (And if you have multiple agents in a fleet, all writing to the same memory store, the namespace isolation suddenly matters a lot.)

The next thing I want to ship is a streaming-write API on pg-raggraph — `rag.write_episode(...)` that takes a single completed task and ingests it incrementally without batching. Plus a `rag.recent(...)` query that returns the last N episodes filtered by current task context. Probably a few weeks of work on top of what's already built.

After that, the harder questions become real. What's the right forgetting policy? How does the agent know what's *its* memory vs the team's shared memory? Who owns retraction — the agent (it learned the fact was wrong) or the user (no, you should remember this)?

I don't have clean answers to those yet. The architectural foundation looks right; the policy layer is research, not engineering.

## What this means if you're building an agent

Three concrete things, then I'll shut up.

First. If you're using vector-only memory (Pinecone, Mem0, LangGraph's vector store, whatever), and your agent is making "oh I forgot we already discussed this" mistakes, the problem is probably not your embedder. It's that vector retrieval can't traverse relationships and your agent's memory has graph-shaped structure (entity, time, prior decision) that vector similarity can't recover.

Second. Try pg-raggraph for the relational-memory layer specifically. Not for everything — your conversational state still belongs in a session log; your factual corpus still belongs in regular RAG. But the *episodic, relational, time-anchored* memory is exactly what the schema and retrieval modes were designed to express. The Tier 1 evolution-awareness is the differentiator.

Third. Don't take the architecture sketch I gave above as a finished product. The streaming write path doesn't exist yet. The forgetting policies are research-grade. The benchmarks at 50K+ document scale haven't run. If you build on it, you're an early adopter, with the upside (real graph-shaped memory) and the downside (you're going to find bugs I haven't seen yet).

I think this is one of the higher-leverage problems in AI engineering right now, and pg-raggraph happens to be shaped right for it. The work to close the gap from "architecture fits" to "production ready" is real but bounded.

What's your agent forgetting that it shouldn't, and is the structure of that forgetting episodic, relational, or just plain factual?
