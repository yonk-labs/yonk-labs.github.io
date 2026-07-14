---
title: "Why on Earth Would You Run AI Inside the Database?"
date: 2026-07-16
draft: false
tags: ["postgres", "llm", "ai-infrastructure", "data-gravity", "operations"]
summary: "A defense of in-database AI agents: data gravity, security, transactional isolation, backups, replication, and why pg-synapse lives inside Postgres on purpose."
build:
  list: never
---

I want to start this one with a question I've gotten, in some form, at least once a month for the past year.

"You built an agent runtime. Why would you put it inside the database?"

The polite version is "interesting choice." The less polite version is "that's a weird place for an LLM." I have heard both. I've heard "the database is for data, not for compute," which is a sentence I want to retire from every conference talk I've ever sat through.

Look, I'm going to defend the weird choice. I'm going to make the case that the database is exactly where an agent belongs when the agent's job is to operate on data, and that the standard pattern (a separate Python or Node service that talks to the database over the network) is a tax we've been paying for so long we forgot it was a tax. I'll do it from the angle an operator cares about: data movement, latency, security, operations, backups, and replication. If you walk away unconvinced, that's fine. At least we'll have a shared vocabulary.

The summary version is this: data has gravity, the database already does the things you need a separate agent runtime to do (just badly, because of the network), and bolting the agent onto the database means the database's operational machinery comes along for free.

## The data gravity argument nobody talks about

Twenty years in databases and the same lesson keeps repeating: data has gravity. The bigger the dataset, the more services get pulled toward it. You don't push terabytes to a model service. You pull the model to the data.

Every agent framework I've worked with in the last three years implicitly assumes the opposite. The agent lives somewhere else. The data lives somewhere else. A polite little network request hops between them, carrying every row the agent wants to look at. For a 100-row demo, fine. For a 10-million-row `orders` table, you either ETL the whole thing (and now you have a freshness problem), or you let the agent page through it with `LIMIT/OFFSET` (and now you have a correctness problem), or you build a "retrieval" layer (and now you have a vector store plus a search index plus a freshness pipeline plus the original database, and the agent still has to talk to all of them).

The in-database version of this is just: `SELECT * FROM orders WHERE ...`. Same SQL. Same planner. Same indexes. Same freshness. No ETL hop. No "is the staging table up to date." No "we missed the last CDC window."

The `examples/customer-support-triage/` example is the cleanest demonstration. The agent reads `support.tickets`, joins against `support.customers` to pull the customer's tier, classifies by category and priority, and writes back. The data never leaves the database. No ETL hop, no vector store, no "we'll fetch the tickets from the API." The agent runs against live data because the agent is *in* the database with the live data.

That's not a small thing. That's the entire data engineering pipeline evaporating.

## The latency argument that's hiding in plain sight

Let me put numbers on it for the people who like numbers.

In-process pgrx path: the kernel runs in the same process as Postgres. SPI talks to the backend directly. No network hop. A tool call that does `sql_exec` is the same code path as a `psql` session running `INSERT`. We're talking microseconds for the dispatch. The work happens inside the transaction the caller is already in.

Out-of-process sidecar path: same kernel, one network hop to the database. Still single-digit milliseconds, but not in-process.

A typical "agent in a separate service" architecture: agent service to LLM (HTTPS), agent service to vector store (HTTPS), agent service to database (TCP). Three hops. Each hop is its own retry policy, its own timeout, its own observability story, its own failure mode. The "agent latency" you see is actually the sum of three independent services' latencies, and any one of them being slow tanks the whole thing.

If you've ever debugged an agent that "randomly takes 8 seconds sometimes," you know what I'm talking about.

Now add the SAVEPOINT-per-tool-call model. In pg-synapse v0.1.1, every tool dispatch runs inside a Postgres internal subtransaction. That means a failing later tool call doesn't discard an earlier tool's writes. The first tool's INSERT is already committed (within the outer transaction); the second tool's failure rolls back to the savepoint and the model sees the error in the next turn. That is the right failure-isolation semantic, and it's free because it's how Postgres already works.

The "agent that uses transactions" pattern is something every framework reinvents. We get it from the substrate.

## Security: the agent cannot exceed the caller's grants

This is the one I want operators to actually read.

The built-in `sql_query` and `sql_exec` tools execute via SPI using the `CURRENT_USER` role. Not the `SECURITY DEFINER` role of the wrapping function. The role that called `synapse.execute(...)`. So if `alice` (a junior analyst) calls `synapse.execute('notes_agent', ...)`, the agent's SQL tool calls run as `alice`. If `alice` doesn't have INSERT on `billing.invoices`, the agent cannot insert into `billing.invoices` either. If the model hallucinates a `DROP TABLE`, the SPI call gets a permission denied and the model sees the error in its next turn. The transaction is unaffected. The agent's tool error is recorded in `synapse.messages`. The whole thing is auditable.

> The agent cannot escape the caller's privileges.

That's a sentence I want to put on a poster. It is the operational security model you've been wanting from every agent framework, and the only way to get it for real is to run the agent where the database's auth model already lives.

Compare that to the standard pattern: a separate service with its own service account. The service account needs `GRANT INSERT ON billing.invoices TO agent_service` because *every* call comes from that role. Now your privilege boundary is "the service," not "the user who initiated the action." For SOC 2, that is a mess. For HIPAA, that is a mess. For anything where the auditor asks "who actually accessed this row," you have to rebuild attribution from logs because the database has no idea who initiated.

In-database execution: the database knows. The database has always known. We just stopped using it.

One caveat, in the interest of honesty: the pgrx host enforces this for free. The sidecar host has the same intent on the v0.2 backlog (it currently runs every `sql_exec` as the pool role). If you're using the sidecar against a managed Postgres today, treat the SQL tools as if they're running with the service account's grants, and don't give that service account anything you wouldn't give a human analyst. We're closing this gap; it's just not closed yet.

## Operational efficiency: the database already does the things

Here's the part where I get to be a little smug, because this is genuinely the best part.

When you put the agent inside the database, the database's entire operational machinery applies to the agent. You don't bolt on a new thing. You don't deploy a new service. You don't add it to your Kubernetes manifests, your service mesh, your observability stack, your secrets vault, your auth provider, your runbook.

Let me itemize it.

**Backups.** Every agent definition is a row in `synapse.agents`. Every LLM profile is a row in `synapse.llm_profiles`. Every secret is a row in `synapse.secrets`. Every execution transcript is a row in `synapse.executions` plus `synapse.messages` plus `synapse.traces`. `pg_dump`, `pg_basebackup`, filesystem snapshots, WAL archiving, all of it carries the agent runtime along. There is no separate backup plan. There is no "did we back up the agent service config." It's a database, you back up the database.

**Point-in-time recovery.** PITR restores agent state to the snapshot time, including the in-flight queue, the message transcripts, the secrets, the LLM profiles. The same fidelity as any other table. Because it *is* any other table.

**Streaming replication.** A read replica gets the agent definitions, the profiles, the secrets (encrypted at rest if you're doing that), the execution history. The replica is, in some sense, "the agent runtime with a delay." Replication lag applies to agents exactly as it applies to anything else in the database. The semantics are well-understood because they're Postgres semantics, not "we invented a new thing."

**Logical replication.** You can `PUBLICATION ... FOR TABLE synapse.agents, synapse.executions, synapse.messages, synapse.traces` and replicate them to a standby or a warehouse. This is not in the docs as a recommended setup, because the project is honest that it hasn't been battle-tested across every replication topology. But it follows from the architecture. Everything is a table. Tables replicate.

**Cancel and timeout.** `statement_timeout` works. `pg_cancel_backend()` works. They're wired through the kernel's interrupt probe so a cancelled run aborts cleanly between LLM turns with `ExecutorError::Cancelled`. The wall-clock `timeout_ms` GUC is enforced at the runtime chokepoint, so a hung provider call no longer parks a backend indefinitely. This was a real bug in v0.1; it's fixed in v0.1.1.

**Failover semantics.** A failing-over Postgres terminates backend connections, which terminates in-flight agent runs. The pre-inserted `synapse.executions` row reflects the failure. The `synapse.agent_queue` is durable across the restart and `synapse.drain_queue()` picks up where it left off. Same as any other client connection. No special handling.

**Observability.** The full message trace is in `synapse.messages`. You can `SELECT * FROM synapse.executions WHERE status = 'errored' AND duration_ms > 5000` to find slow failures, run `pgaudit` on the tables, ship the rows to your warehouse, or chart them in your existing dashboards. The agent observability story is "the database's observability story." Which you already have.

**Panic containment.** A plugin tool that `panic!`s gets caught by `dispatch_tool_call`'s `catch_unwind`. The panic degrades to a tool error fed back to the model. The transaction is unaffected. This is real, it's in the v0.1.1 changelog, and it's the kind of thing that took the Python agent world years to figure out via `concurrent.futures` and careful executor design.

**SSRF guard.** The HTTP tools default-deny loopback, RFC1918, link-local, IPv6 equivalents, and resolve DNS to reject hostnames that point at internal addresses. The `169.254.169.254` cloud metadata endpoint is in the block list by default. Operators allowlist hosts via env var. This isn't even a Postgres thing, it's just "the agent runtime has the security stance you would have built yourself if you had time."

I want to call out one more, because it's the under-appreciated one.

**Cost cap and iteration cap as data.** `agents.cost_cap_usd` is a `NUMERIC(12,6)` column. `agents.max_iterations` is an `INTEGER`. `agents.timeout_ms` is a `BIGINT`. These are database fields. You can `SELECT * FROM synapse.agents WHERE cost_cap_usd IS NULL` and find the agents nobody configured a cost cap on. You can write a `pg_cron` job that emails you when an agent exceeds its cap. You can audit them in your quarterly access review. They are rows in a table. They get the same treatment as any other config row.

## The "but the database is for data, not for compute" take

I've heard this one enough times to have a stock answer.

The database is *for* data. That's why the agent belongs there. The agent's job is to operate on data. The data lives in the database. Putting the agent somewhere else is the weird choice when you stare at it for more than five seconds.

The right-sized comparison isn't "agent in the database vs. agent in a service." It's "agent in the database vs. agent in a service that talks to the database over the network." The first one has zero data movement, zero new auth model, zero new backup plan, zero new observability stack. The second has all of those, and now you have a distributed system. Distributed systems are hard. In-database agents are not a distributed system. They're a feature of your existing database.

I'm not saying don't use a separate service when you need one. (The pg-synapse sidecar exists exactly for the case where you can't extend your Postgres, like RDS or Cloud SQL. Same kernel, network hop, different deployment shape.) I'm saying the default should be "in the database," and we should need a really good reason to deviate.

## The real talk

There's a reason every agent framework you've heard of is a separate service. It started in the Python ecosystem, where "deploy a Flask app" was the default shape. The shape got cargo-culted. The shape assumed the database was a remote store. The shape worked for demos and stopped working at scale.

What we're betting on with pg-synapse is that "the agent is a database feature" is a better default shape, because the database already has the security model, the transaction model, the audit story, the backup story, the replication story, the observability story. We're not innovating in those areas. We're using what was already there. (Sorry, I'm a recovering consultant. The L-word muscle memory is real.)

A few things I want you to take away.

One: every claim I made about "the database already does that" is true *because* we put the agent runtime inside it. If the agent were a separate service, none of this would be true. The architecture is the feature.

Two: this is not a "Postgres is the best database" argument. The same shape works for any database with stored procedures and SPI-equivalents. Postgres just happens to be the one where I want to spend my time.

Three: the in-database path is not the only path. The sidecar exists for managed Postgres. You'll pick the pgrx path when latency matters and you can install a `.so`. You'll pick the sidecar when you can't. Same kernel, same SQL surface, same `Plugin` model.

Four: I'm not done arguing about this. I expect to keep having the conversation. I'm right. You're allowed to disagree. Let's see how it goes.

So: what does your data pipeline look like? How many services are between your LLM and your production data? Have you counted the network hops? Have you checked whether your service-account grants match your least-privilege intent?

I'm betting the answer is "no, and they don't."
