---
title: "How to Actually Build an Agent on Postgres (a pg-synapse Tutorial)"
date: 2026-07-15
draft: false
tags: ["postgres", "llm", "agents", "tutorial", "rust"]
summary: "A working tutorial: install pg-synapse, write a tool, register an LLM profile, create an agent as a row, run it from SQL, attach a reactive trigger. All copy-pasteable."
build:
  list: never
---

Look, [last post](/blog/pg-synapse-intro-architecture/) I told you what pg-synapse is and why we built it. This post I want to do the thing I always wish blog posts would do: actually walk through it end to end. By the end of this you should have a Postgres with an agent in it, that you can call from `psql`, that you can attach to a trigger, that you can read the transcript of. The whole thing takes about ten minutes if you have an LLM endpoint handy.

I'm going to assume you're on a Linux box with Postgres 17 and an OpenAI-compatible LLM endpoint. (vLLM, llama.cpp-server, LM Studio, real OpenAI, all work.) If you don't have one, the docker-compose demo in the repo brings up Postgres + the web UI and you point the UI at any reachable endpoint. I'll show that path too.

## Step 1: Install the extension

First, you need `cargo-pgrx` pinned to the version pg-synapse uses. (Don't skip this. The kernel pins `pgrx = "=0.18.0"`. If `cargo pgrx` errors with a 0.17 path, your binary drifted. Reinstall.)

```bash
cargo install --locked cargo-pgrx --version 0.18.0
cargo pgrx init                       # one-time, sets up the managed Postgres
cargo pgrx install --features pg17 --no-default-features
```

That drops a `pg_synapse_pgrx.so` into the Postgres extension directory. In a normal install you'd `CREATE EXTENSION pg_synapse_pgrx;` and you're done. In the docker-compose demo this happens automatically via `demo/db/initdb/10-create-extension.sql` on first boot.

Want the no-friction path? This is what I do when I just want to play:

```bash
git clone https://github.com/anomalyco/pg-synapse.git
cd pg-synapse
docker compose up --build
```

That brings up Postgres 17 with the extension baked in (on `:55432`) and an axum web harness (on `:8080` by default, or `HARNESS_PORT=8091 docker compose up` if you've got something else there). Open the UI, drop your endpoint URL and API key into the connection bar, and you're driving the same `synapse.*` SQL surface through a web frontend. The whole thing is reproducible end to end and there's a captured `EXAMPLE_OUTPUT.md` for each demo scenario.

For the rest of this post I'm going to assume you're in `psql` against a fresh database. Whether that's the docker-compose Postgres or your own, the SQL is the same.

A heads up before we start. The project's CLAUDE.md has a rule against em-dashes and I'm going to honor it because I'm too tired to argue with myself about typography. So is every code comment in this post. You're welcome.

## Step 2: Point the agent at a model

Before an agent can do anything, the kernel needs an LLM profile. A profile is a row in `synapse.llm_profiles`: provider name, model, base URL, optional API key secret, JSONB params bag. The base URL is what makes this thing generic; the same `openai` provider hits real OpenAI, vLLM, llama.cpp-server, LM Studio, or the Ollama OpenAI shim. Set the URL, set the model, move on.

If you're using a real key, do not inline it. Stash it in `synapse.secrets` and reference it by name:

```sql
SELECT synapse.secret_set('openai_key', 'sk-your-key-here');
SELECT synapse.llm_profile_set(
  'my_llm',
  'openai',
  'gpt-4o-mini',
  'https://api.openai.com/v1',
  'openai_key',                 -- name of the secret in synapse.secrets
  '{}'::jsonb
);
```

If you're pointing at a local vLLM that doesn't need a key:

```sql
SELECT synapse.llm_profile_set(
  'local_vllm',
  'openai',
  'Intel/Qwen3-Coder-Next-int4-AutoRound',
  'http://192.168.1.193:8000/v1',
  NULL,
  '{}'::jsonb
);
```

That's it. One row, one profile. `synapse.llm_profile_set` is `SECURITY DEFINER`, rebuilds the kernel cache, and the next `execute()` call rehydrates with the new profile.

There are GUC fallbacks for everything you might forget to set: `pg_synapse.default_llm_profile_main`, `default_llm_profile_small`, `default_llm_profile_judge`, `default_embedding_profile`, `default_timeout_ms`, `default_max_iterations`, `default_cost_cap_usd`. Set them in `postgresql.conf` or `ALTER SYSTEM SET` and the agent row picks them up automatically. I bring this up because the first time I forgot to set a timeout and watched a runaway loop eat my weekend, I wished I'd read this paragraph.

## Step 3: Pick tools

Out of the box you get:

- `sql_query` and `sql_exec` (read and write Postgres through SPI as the calling role)
- `http_get`, `http_post`, `http_head` (default-deny SSRF guard: loopback, RFC1918, link-local including the `169.254.169.254` cloud metadata endpoint, all blocked unless allowlisted)
- `read_file`, `write_file`, `list_dir`, `edit_file`, `grep`, `list_files` (sandboxed filesystem under `/tmp/pg_synapse_fs`)
- `calculator`, `get_current_time`, `call_agent` (re-enters the runtime on a named sub-agent)

For this tutorial we're going to use `sql_query` and `sql_exec` because they let the agent actually do work on your data. That's the whole point.

The privilege model here is the part I want you to internalize. The kernel's `sql_query` and `sql_exec` tools execute via SPI as `CURRENT_USER`. Not as the `SECURITY DEFINER` role of the wrapping function. As the role that called `synapse.execute(...)`. So if `alice` calls the agent, the agent's SQL tool calls run as `alice`. If `alice` doesn't have INSERT on `billing.invoices`, the agent can't insert into `billing.invoices` either. The agent cannot exceed the caller's grants.

I know that sounds obvious. It is obvious. And it is, somehow, *unique* in the agent framework space. Make a note of it. We'll come back to it in the next post.

## Step 4: Register an agent

An agent is a row in `synapse.agents`. The system prompt lives there. So does the tool allow-list, the executor name, the per-agent timeout, the iteration cap, the cost cap. This is your config table.

```sql
CREATE SCHEMA IF NOT EXISTS demo;
CREATE TABLE IF NOT EXISTS demo.notes (
  id       SERIAL PRIMARY KEY,
  body     TEXT NOT NULL,
  added_by TEXT,
  added_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO demo.notes (body, added_by) VALUES
  ('Buy milk', 'seed'),
  ('Call mom', 'seed')
ON CONFLICT DO NOTHING;
```

Now register the agent:

```sql
SELECT synapse.agent_create(
  'notes_agent',
  $$You are an assistant that manages a demo.notes table.
You may use sql_query and sql_exec to read and write that table.

When asked to add a note, call sql_exec with:
  query:  INSERT INTO demo.notes (body, added_by) VALUES ($1, $2)
  params: ["<the note text>", "agent"]
When asked what is in the table, call sql_query with:
  query:  SELECT id, body, added_by FROM demo.notes ORDER BY id
  params: []

Always pass values through the params array using $1, $2, ... placeholders.
Never inline literal values into the SQL string; parameter binding is the
supported and injection-safe path.$$,
  'conversation',           -- executor name
  'local_vllm',             -- main LLM profile
  ARRAY['sql_query', 'sql_exec'],
  5,                        -- max_iterations
  60000                     -- timeout_ms
);
```

Couple things worth flagging before you run this.

First, the system prompt explicitly tells the model to use `$1, $2` placeholders and a `params` array. That's how the SQL tool binds values. Don't let your model inline literals. (The v0.1 release had a stringified-int coercion bug where an LLM emitting `"3"` for a `bigint` column parameter didn't bind as INT8. v0.1.1 fixed it. If you're upgrading from v0.1, double-check your system prompts; the explicit `$N` pattern is what you want.)

Second, `max_iterations=5` is plenty for a notes agent. You'll want to tune this per agent. The wall-clock `timeout_ms=60000` is enforced at the runtime chokepoint in v0.1.1; pre-v0.1.1 it was dead plumbing and a hung provider could park a backend for `max_iterations * per-request timeout`. Don't run pre-v0.1.1 in production.

Third, every `synapse.agent_create()` (and every profile / secret / tool mutation) calls `rebuild_kernel()`. The cached kernel goes stale, the next `execute()` rehydrates from the configuration tables. You don't have to bounce Postgres.

## Step 5: Run it

```sql
SELECT synapse.execute('notes_agent', 'Add a note that says "Hello from pg_synapse!"');
```

You get a JSONB envelope back:

```json
{
  "execution_id": "0a3e...",
  "output": "I've added your note. There's now a row with body 'Hello from pg_synapse!'.",
  "status": "completed",
  "tokens_in":  412,
  "tokens_out": 78,
  "cost_usd":   null,
  "duration_ms": 1840,
  "tool_calls": [
    {"name": "sql_exec", "args": {"query": "INSERT INTO demo.notes (body, added_by) VALUES ($1, $2)", "params": ["Hello from pg_synapse!", "agent"]}}
  ]
}
```

Notice the tool call: `$1, $2` with values bound through `params`. That's what good looks like.

Now ask it to read the table:

```sql
SELECT synapse.execute('notes_agent', 'What notes are in the table?');
```

And look at the actual data:

```sql
SELECT * FROM demo.notes ORDER BY id;
```

That's the loop. Model thinks, model calls a tool, kernel dispatches the tool under your role, tool result flows back into the model, loop continues until the model returns text or you hit `max_iterations`. The whole transcript is in `synapse.executions` + `synapse.messages` + `synapse.traces`, all regular Postgres tables.

## Step 6: Read the transcript like an audit log

```sql
SELECT seq, role, tool_name, content
FROM synapse.messages
WHERE execution_id = '0a3e...'
ORDER BY seq;
```

You get something like:

```
 seq | role | tool_name | content
-----+------+-----------+---------
   1 | user |           | Add a note that says "Hello from pg_synapse!"
   2 | asst | sql_exec  | {"query": "INSERT INTO demo.notes (body, added_by) VALUES ($1, $2)", "params": [...]}
   3 | tool |           | {"command_tag": "INSERT 0 1"}
   4 | asst |           | I've added your note. ...
```

Plain SQL. Your existing observability stack (pgaudit, log shipping, pg_stat_statements, whatever you've got) just works. Nothing about this transcript lives outside the database. We didn't ship a separate "agent observability" product. We didn't have to. The database already had one.

If you want to clean up old runs:

```sql
SELECT synapse.purge_traces(30);  -- delete runs older than 30 days
```

That cascade-deletes the messages and traces too. One function call.

## Step 7: Write your own tool

If the built-ins don't cover it, you write a tool. The fast path is `#[derive(Tool)]`. Here's a real tool, borrowed from `pg-synapse-tools-http` and trimmed for clarity:

```rust
use pg_synapse_core::error::ToolError;
use pg_synapse_core::types::{ToolCtx, ToolOutput};
use pg_synapse_macros::Tool as DeriveTool;
use schemars::JsonSchema;
use serde::Deserialize;
use std::collections::BTreeMap;

#[derive(DeriveTool, JsonSchema, Deserialize, Debug)]
#[tool(name = "http_get",
       description = "Fetch a URL via HTTP GET. Returns status and body as text.")]
pub struct HttpGet {
    /// URL to fetch. Must be http or https. Loopback and RFC1918 hosts are blocked.
    pub url: String,
    /// Optional request headers.
    #[serde(default)]
    pub headers: BTreeMap<String, String>,
}

impl HttpGet {
    async fn run(self, _ctx: &ToolCtx) -> Result<ToolOutput, ToolError> {
        // ... build reqwest client, do GET, return text ...
        Ok(ToolOutput::Text("...".into()))
    }
}
```

That's the whole tool. The macro generates `name()`, `schema()` (cached in a `OnceLock` so it only builds once), and `run()` that deserializes the input into `Self` and calls your inherent `async fn run(self, ctx: &ToolCtx)`. Field doc comments flow into the JSON Schema automatically, so the model sees them.

Three things to know:

1. The macro emits two associated consts `TOOL_NAME` and `TOOL_DESCRIPTION`. Useful for logging and tests.
2. `#[tool(name = ..., description = ...)]` is the only supported attribute. `name` defaults to the struct ident lowercased; `description` defaults to empty.
3. Use `#[derive(Tool)]` for "almost everything." Drop to a manual `Tool` impl when the schema must be dynamic, the input type can't derive `JsonSchema`, or `run` needs `&self` stateful behavior. Use the MCP client when the capability already exists as an MCP server and you'd rather integrate than reimplement.

You then register the plugin at startup (or in your host's plugin list), and the kernel picks it up next time the registry rehydrates.

## Step 8: Bolt it to a trigger

This is the part where it stops being a demo and starts being infrastructure.

```sql
SELECT synapse.attach_agent_trigger(
  target_table => 'demo.notes',
  agent        => 'notes_agent',
  mode         => 'queue',       -- 'queue' (async) or 'inline' (transactional gate)
  events       => 'INSERT',
  when_sql     => NULL,
  input_expr   => 'NEW.body'
);
```

That generates a row-level AFTER trigger and trigger function on `demo.notes`. From now on, every `INSERT INTO demo.notes` enqueues a job in `synapse.agent_queue`. The trigger doesn't block. The INSERT commits. Later, you (or `pg_cron`) runs:

```sql
SELECT synapse.drain_queue(10);
```

which atomically claims up to 10 queued rows (`FOR UPDATE SKIP LOCKED`, idempotent, concurrency-safe) and runs `synapse.execute()` on each.

The other mode is `inline`:

```sql
SELECT synapse.attach_agent_trigger(
  target_table => 'demo.notes',
  agent        => 'notes_agent',
  mode         => 'inline',
  input_expr   => 'NEW.body'
);
```

Now the agent runs *inside* the INSERT transaction. If the agent calls `RAISE EXCEPTION 'note contains PII'`, the write rolls back. The agent is a transactional gate. This is the "policy agent" pattern, and it's the one that makes auditors happy.

There's a recursion guard (`pg_trigger_depth() > 1`) so an agent that writes to the same table doesn't infinitely re-trigger itself. Don't remove it. (Yes, I tried. Don't.)

## What to look at next

A few things I'd poke at, in order of "how much they'll change how you think about this":

- The **autonomous index tuner** scenario in `demo/harness/scenarios/index_tuner.sql`. It runs an agent against a 100k-row table that EXPLAINs, finds a missing index, runs `CREATE INDEX`, re-EXPLAINs, and watches the plan flip. All transaction-safe. This one made me say "oh" out loud the first time I watched it.
- **DBA that opens tickets**. Same shape, but the agent decides "this is fixable" vs "this is a ticket for a human" based on what's safe inside a transaction. Important because it's the agent modeling its own limits.
- The **customer-support triage** example. Multi-step agent, reads tickets, joins against a customer table to pull the tier, classifies, writes back. Pure SQL, no data leaves the database.
- The **reactive triggers** example, if you skipped it above. Both trigger modes end to end, rollback behavior shown.
- The **plugin-development** doc, if you want to write your own LLM provider. The shape is four impls. I timed it; you can have a working custom provider in an afternoon.

## The real talk part

Here's what I'd want you to walk away with.

You can stand up an agent in Postgres in under ten minutes. The whole config is SQL. The whole transcript is SQL. The whole observability story is "run a SELECT." There's no new tool, no new dashboard, no new auth model, no new service to monitor. The agent is a row in your database, and you call it like a stored procedure.

You can attach that agent to a trigger and have it enrich, validate, or transform every row that hits a table. That's not a toy. That's a feature.

You can write a custom tool in 30 lines of Rust, drop it in a plugin crate, and the kernel picks it up next time it rehydrates. No framework lock-in. Just a substrate you build on.

Want the long-form version? Go read `docs/extension-quickstart.md`. Prefer the path of least resistance? Run `examples/sql-agent-readwrite/run.sh`. And if you just want to click around a web UI, spin up the docker-compose demo.

Next post I'll make the case for *why* this is the right shape, because I've had three different people in three different weeks tell me I'm crazy and I want to put it on paper. Data movement, operations, backups, replication, the whole thing.

What's the first agent you'd put in your database?
