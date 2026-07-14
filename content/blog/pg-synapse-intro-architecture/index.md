---
title: "pg-synapse: Run AI Agents From SQL, Like a Stored Procedure"
date: 2026-07-14
draft: false
tags: ["postgres", "llm", "agents", "rust", "open-source"]
summary: "pg-synapse is a Postgres-native agent loop runtime in Rust. Invoke LLM agents from SQL, with tools that read and write your database under the caller's grants."
build:
  list: never
---

So here's a question that has bugged me for a couple of years now. You have a Postgres database full of your most important data. You want an LLM agent to do work on that data. Where does the agent run?

The default answer, today, is "somewhere else." A Python service. A Node.js box. A separate cluster with its own deployment story, its own secrets store, its own auth model, its own observability stack, and a polite-but-firm network hop in front of every single row it wants to read. We've collectively decided that the right place for an AI to operate on production data is... outside the database that holds it.

I think that's wrong. And I built something to prove it.

[`pg_synapse`](https://github.com/yonk-labs/pg-synapse) is a Postgres-native agent-loop runtime written in Rust. You register an agent as a row in a table. You call it from SQL like a stored procedure. The agent runs a real tool-calling loop against an LLM, and the tools it calls can read and write the very Postgres tables the agent lives in, under the calling role's existing grants. No privilege escape. No new auth model. No "well, the service account has to be granted on everything."

```sql
SELECT synapse.execute('notes_agent', 'Add a note that says "Hello"');
```

That single line runs an agent that talks to an LLM, gets back a tool call, dispatches it through SPI as your Postgres role, and writes the row. The whole transcript lands in `synapse.executions` and `synapse.messages` so you can `SELECT * FROM it` like any other audit log. The kernel that powers this is six traits, three reference executors, and a `tower::Service` seam. Everything opinionated (providers, memory, compression, embeddings) is a plugin.

Look, I'm not going to pretend this is a small idea. It's not. It's "agents should be a database feature" taken seriously, and we're shipping it. Let me walk you through what's actually inside.

## Why "inside the database" is even worth saying

I'm going to borrow a framing from the design doc, because it nails the gap.

> Operators who want agents to feel like stored procedures have no public-domain option. They either reinvent the runtime or move out of Postgres entirely.

That's the gap. Every agent framework you've heard of (LangChain, LangGraph, LlamaIndex, OpenAI Agents SDK, Anthropic's, the Rust crew like Rig) assumes the host is a general-purpose Python or TypeScript process. The framework isn't *wrong*, it's just solving for a different deployment shape. Nobody is solving for "I want to invoke an agent from inside the database, with the database's security model, in the database's transaction."

So that's what we built. The hard rules we set for ourselves:

- **Six traits in the kernel. Everything else is a plugin.** Not because plugins are cool (they are), but because a kernel that does no I/O and ships zero opinions stays testable. The kernel is `pg-synapse-core`. It does not know about OpenAI. It does not know about HTTP. It does not know about Postgres. Hosts and plugins supply all of that.
- **Typed errors at every boundary.** No `Result<_, String>`. No `Box<dyn Error>`. Every error in the kernel extends an enum, implements `Serialize + Deserialize`, and round-trips cleanly through SQL trace rows.
- **No `unsafe` in the kernel or plugins.** The pgrx host is the only place `unsafe` could appear (FFI), and even there we keep it to a minimum with `SAFETY:` notes.
- **No em-dashes anywhere.** (This is going to make me twitch by the end of this post.)

## The kernel: six traits, three executors

The kernel is small on purpose. Here's the surface:

| Trait | Purpose |
|---|---|
| `Executor` | A control-flow strategy. Implements `async execute(ExecutionContext) -> ExecutorOutcome`. |
| `Tool` | A callable capability. Schema is JSON Schema, output is `Text \| Json \| Empty`. |
| `LlmProvider` | Talks to a model. Returns a capability manifest (`tool_use`, `streaming`, `json_mode`, `vision`, context length, output length) so the runtime can pre-flight reject mismatches. |
| `EmbeddingProvider` | Same shape as `LlmProvider`, but for dense vectors. |
| `MemoryProvider` | `read`, `write`, `search` on a scoped namespace. No default impl; plugs in via plugin. |
| `Compressor` | Trims context when it gets too long. Also a plugin (no default in core, on purpose). |

Three executors ship out of the box, and they all share an internal `LoopHarness` that owns the iteration count, the cost accumulator, and the message history:

```sql
SELECT synapse.execute('notes_agent', 'Add a note that says "Hello"');
```

returns a JSONB envelope:

```json
{
  "execution_id": "uuid",
  "output": "the assistant's final text",
  "status": "completed",
  "tokens_in":  412,
  "tokens_out":  78,
  "cost_usd":   null,
  "duration_ms": 1840,
  "tool_calls": [{"name": "sql_query", "args": {"query": "..."}}]
}
```

Errors come back as `{"error": "...", "status": "errored"}` instead of raising, so a caller can `... ->> 'status'` in plain SQL and route accordingly. Every run logs to `synapse.executions` + `synapse.messages` + `synapse.traces`. Plain SQL observability, no new tool to learn.

Around `execute` the v1 surface covers the lifecycle: async variants (`execute_async`, `execution_status`), agent CRUD (`agent_create`, `agent_drop`, `agent_set_trace_level`, `agent_list`), profile CRUD (`llm_profile_set`, `embedding_profile_set`, `secret_set`, plus their `_drop` siblings), tool registration (`tool_register`, `tool_list`, `tool_call`), embedding (`embed`), housekeeping (`version`, `rebuild_kernel`, `purge_traces`, `provider_capabilities`), and the reactive-trigger pair (`attach_agent_trigger`, `detach_agent_trigger`, `enqueue`, `drain_queue`). That's the whole v1 surface. Reasonable, right?

The reactive triggers are worth a callout because they're the part that made me grin when I read it. `attach_agent_trigger('orders', 'policy_agent', mode => 'inline')` generates a row-level AFTER trigger on `orders`. In queue mode the INSERT commits immediately and a job lands in `synapse.agent_queue` for later drainage. In inline mode the agent gates the INSERT inside the transaction and can `RAISE EXCEPTION` to roll back the write. So you can ship "agent validates every order write" as a SQL function call. No external scheduler, no message bus, no deployment pipeline.

## What ships today

Status check: v0.1.1 is out. Plus PS-4 (redacted diagnostics export) and PS-5 (provider conformance suite) on `main`. Both the pgrx extension and the sidecar binary are shipped and verified live. Plugins in the workspace:

- **Providers:** OpenAI-compatible, Anthropic, llama.cpp-server (with optional GGUF download).
- **Embeddings:** ONNX Runtime (BGE-small, BGE-base, anything BERT-arch).
- **Tools:** HTTP (with default-deny SSRF guard, including the `169.254.169.254` cloud metadata block), SQL (SPI on pgrx, sqlx on sidecar), sandboxed filesystem, calc, clock, delegate (re-enters `Runtime::execute` on a sub-agent), [lede](https://github.com/yonk-labs/lede) compression, lexicon schema-context.
- **Compaction:** deterministic extractive compressor.

Six scenarios ship baked into the web demo, including the ones that made me laugh out loud: an autonomous index tuner (agent EXPLAINs, sees Seq Scan on a 100k-row table, runs `CREATE INDEX` transaction-safe, re-EXPLAINs, watches the plan flip). A DBA that opens tickets. LLM-powered ETL where the agent normalizes "Deutschland / SPAIN / U.K. / the states" into ISO codes entirely inside the database. (More on that last one in the next post.)

## So what?

Three things I want to leave you with.

**One**, the kernel is boring on purpose. Six traits. Three executors. Typed errors. No magic. If you've ever debugged an agent framework at 3am and wanted to read the loop in 200 lines, this is that.

**Two**, everything opinionated is a plugin. If you don't like the OpenAI provider, write a different one. The shape is four impls and you're done. The kernel doesn't care.

**Three**, the whole thing is reachable from SQL. That's the bet. That's the weird thing. That's the part where you either see it or you don't. I think once you see it, you can't unsee it.

I'll write the next post on how to actually build agents on this. We're going to register a profile, write a tool, register an agent, watch it run, and inspect the transcript. It'll be a working tutorial you can paste into psql.

You want agents to feel like database features. We've been building agents like features of an application server, and then spending years gluing the application server to the database. There's a better shape. It's the shape Postgres already has.

What do you think? Am I wrong about this?
