---
title: "pg-synapse"
date: 2026-07-01
draft: false
tags: ["rust", "postgresql", "pgrx", "agents", "mcp", "llm"]
summary: "Postgres-native agent-loop runtime in Rust. Invoke an LLM agent and its tool dispatch from SQL like a stored procedure — the agent reads and writes your tables directly, with a small trait-based kernel and everything else as a plugin."
externalUrl: "https://github.com/yonk-labs/pg-synapse"
---

**pg_synapse** runs an agent loop from inside PostgreSQL:

```sql
SELECT synapse.execute('notes_agent', 'Add a note that says "Hello"');
```

That call runs a real tool-calling loop against an LLM, and the agent's tools can read and write Postgres tables directly — no separate service, no round trip out of the database to hold the loop state.

## Why run the agent loop in the database?

- **The kernel stays small.** Six traits, three reference executors (conversation, react, reflection), a `tower` middleware seam, a built-in MCP client, and a `Runtime` facade. Everything opinionated — providers, memory, compaction, embeddings — is a plugin, not baked into the core.
- **Two host paths, same engine.** A `pgrx` Postgres extension for environments where you can load a shared library, and a `pg-synapse-sidecar` axum binary for managed Postgres where you can't — both run the same kernel.
- **Provider-agnostic tool calling.** Real OpenAI, vLLM, llama-cpp-server, LM Studio, Ollama, and Anthropic's Messages API are all supported provider plugins, verified end-to-end against a live LLM rather than mocked.
- **Middleware composition, not bespoke glue.** Cost caps, retries, tracing, and dedup are `tower::Layer`s you compose, with recipes documented for common combinations.
- **A conformance suite that catches drift.** Golden cassettes per provider plus a drift check catch silent serde-shape changes before they become a production surprise.

## What works today

An agent invoked from SQL that reads and writes tables via `sql_query`/`sql_exec` tool calls; local embeddings through ONNX Runtime (BGE family) callable as `SELECT synapse.embed(...)`; HTTP, SQL, filesystem, calc, clock, and delegate (multi-agent) tools, plus a `#[derive(Tool)]` macro for adding your own; both the `pgrx` extension and the sidecar binary shipped and verified live.

## Quick start

```bash
cargo install --locked cargo-pgrx --version 0.18.0
cargo pgrx init
cargo pgrx install --features pg17 --no-default-features
```

```sql
CREATE EXTENSION pg_synapse_pgrx;

SELECT synapse.llm_profile_set(
  'llm', 'openai', '<model>', 'http://your-endpoint:8000/v1', NULL, '{}'::jsonb);

SELECT synapse.agent_create(
  'asst', 'You are a helpful assistant that can query the database.',
  'conversation', 'llm', ARRAY['sql_query','sql_exec'], 5, 60000);

SELECT synapse.execute('asst', 'How many rows are in public.users?');
```

## Links

- [GitHub Repository](https://github.com/yonk-labs/pg-synapse)
- License: MIT or Apache-2.0, at your option
