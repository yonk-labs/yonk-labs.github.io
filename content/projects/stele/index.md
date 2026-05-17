---
title: "stele"
date: 2026-05-17
draft: false
tags: ["postgresql", "agent-memory", "ai", "agents", "rag"]
summary: "Agentic memory implemented natively in PostgreSQL — the episodic, relational, time-anchored memory layer agents actually forget, kept in the database you already run."
externalUrl: "https://github.com/yonk-labs/stele"
---

**stele** implements agentic memory natively in PostgreSQL. It's aimed at the kind of memory coding and task agents keep losing between sessions — not the conversational scratchpad, but the durable, relational, time-anchored record of what was done, why, and what it connected to.

## Why stele?

Modern agents need three different kinds of memory, and only one of them is plain RAG:

- **Conversational state** — the last N turns. A session log handles this; nothing special needed.
- **Factual recall over a corpus** — what's in the codebase, the runbook, the docs. This is ordinary vector RAG.
- **Relational / episodic memory** — "we tried that last Tuesday, it didn't work, here's the chain of issue → developer → service → prior incident." This is the part current agent tooling drops on the floor, and it's what stele is for.

Keeping it in Postgres means no second system to operate, sync, or back up — the memory lives in the same database the rest of the stack already talks to.

## What it's for

- **Long-running coding agents** — stop re-explaining context the agent should already have every session.
- **Task/workflow agents** — retain the episodic chain across runs so prior decisions and dead ends are retrievable, not re-discovered.
- **Agent middleware** — a durable memory backend that speaks SQL instead of requiring a bespoke memory service.

## Links

- [GitHub Repository](https://github.com/yonk-labs/stele)
