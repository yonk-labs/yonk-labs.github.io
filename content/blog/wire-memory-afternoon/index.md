---
title: "Wire Real Memory Into Your Agent In An Afternoon"
date: 2026-05-27
draft: false
tags: ["chunkshop", "agent-memory", "tutorial", "postgres", "pgvector", "ai", "agents"]
summary: "The practical follow-up to the goldfish-memory post. Bring a Postgres database with pgvector and an agent that talks to users; an hour later you've got two-tier memory bolted on. Staging, realtime and consolidate cells, three scheduling options, three reader patterns, and an LLM fact extractor — Python and Rust both."
build:
  list: never
---

This is the practical follow-up to [Your Agent Has Goldfish Memory](/blog/goldfish-memory/). That post made the case for two-tier agent memory. This post shows you how to actually bolt it on.

Bring a Postgres database with pgvector. Bring an agent that talks to users. The rest takes about an hour, end to end.

(Caveat for the impatient: the first run of the consolidate cell downloads an embedder model. That's a one-time five-second hit. Everything after that runs on cached weights.)

## What you'll have when you're done

```
your agent app  ─────►  stage_event(...)
                          │
                          ▼
                   chunkshop_staging      (one Postgres table)
                          │
                ┌─────────┴─────────┐
                ▼                   ▼
        realtime cell        consolidate cell
       (every minute)        (nightly)
                │                   │
                ▼                   ▼
              agent_memory.memory   (the read surface)
                          │
                          ▼
                  your agent reads it
```

Five steps. Doesn't matter if you're Python or Rust — the schema is the same, the YAML is the same, the cron entry is identical.

## Step 1: Postgres ready

Skip if you've already got a database with pgvector loaded. If not:

```bash
docker run -d --name agent-pg -p 5432:5432 \
  -e POSTGRES_PASSWORD=secret \
  pgvector/pgvector:pg17

psql postgresql://postgres:secret@localhost:5432/postgres \
  -c "CREATE DATABASE agent_memory;"
psql postgresql://postgres:secret@localhost:5432/agent_memory \
  -c "CREATE EXTENSION vector;"
```

That's the whole infrastructure. Postgres + pgvector + an empty database. We're going to let chunkshop create the rest of the schema on its own.

```bash
export CHUNKSHOP_MEMORY_DSN="postgresql://postgres:secret@localhost:5432/agent_memory"
```

Pin this in your shell. It's the only environment variable chunkshop needs for the memory pattern.

## Step 2: Install chunkshop

Python:

```bash
pip install "chunkshop>=0.4.4"
```

Rust — add to `Cargo.toml`:

```toml
[dependencies]
chunkshop-rs = { version = "0.4", features = ["full"] }
```

If you already have chunkshop in your project for ingest work, you've got everything you need. The memory layer is part of the core package — no separate install.

## Step 3: Stage events from your agent loop

This is the only place chunkshop touches your application code. After every user/assistant turn, you call one function:

**Python.** From wherever your message handler lives — Flask, FastAPI, a bare loop, whatever:

```python
import os
from chunkshop.memory import ensure_staging_table, stage_event

# Once, at app startup
ensure_staging_table(os.environ["CHUNKSHOP_MEMORY_DSN"],
                     table="chunkshop_staging")

# After every turn
def handle_message(session_id: str, user_text: str, assistant_text: str, seq: int):
    dsn = os.environ["CHUNKSHOP_MEMORY_DSN"]
    stage_event(dsn, session_id=session_id, role="user",
                content=user_text, seq=seq, table="chunkshop_staging")
    stage_event(dsn, session_id=session_id, role="assistant",
                content=assistant_text, seq=seq + 1,
                table="chunkshop_staging")
```

That's it. `stage_event` is synchronous, fast (about 5ms in practice), and idempotent — re-staging the same turn is a no-op. Your agent doesn't care about embeddings, doesn't care about chunking, doesn't care about consolidation. It just writes turns and moves on.

**Rust.** Same shape:

```rust
use chunkshop::memory::{ensure_staging_table, stage_event, StagedEvent};
use sqlx::PgPool;

async fn handle_turn(pool: &PgPool, session_id: &str, user_text: &str,
                     assistant_text: &str, seq: i64) -> anyhow::Result<()> {
    stage_event(pool, "public", "chunkshop_staging", &StagedEvent {
        session_id: session_id.into(), seq: Some(seq),
        role: Some("user".into()), content: user_text.into(),
        ..Default::default()
    }).await?;
    stage_event(pool, "public", "chunkshop_staging", &StagedEvent {
        session_id: session_id.into(), seq: Some(seq + 1),
        role: Some("assistant".into()), content: assistant_text.into(),
        ..Default::default()
    }).await?;
    Ok(())
}
```

The `event_id` is derived deterministically — sha1 of `session_id\0seq\0content`. Python and Rust derive the same ID for the same canonical input, so an event staged from one and re-staged from the other dedupes cleanly. Useful when you have a Python ingest service and a Rust agent runtime in the same fleet.

## Step 4: Schedule the two cells

Three options, pick the one that fits your deployment:

**Option A — cron.** Drop this in `/etc/cron.d/chunkshop-memory`:

```
CHUNKSHOP_MEMORY_DSN=postgresql://app:secret@db:5432/agent_memory
PATH=/usr/local/bin:/usr/bin:/bin

* * * * *   app   chunkshop ingest --config /etc/chunkshop/memory/realtime.yaml
30 2 * * *  app   chunkshop ingest --config /etc/chunkshop/memory/consolidate.yaml
```

Done. realtime every minute. consolidate nightly at 2:30am. Logs to `/var/log/cron`.

**Option B — Kubernetes.** Two `CronJob` manifests. We ship them in [`docs/samples/memory-scheduling/k8s-cronjob/`](https://github.com/yonk-labs/chunkshop/tree/main/docs/samples/memory-scheduling/k8s-cronjob) — copy them, `kubectl apply`, you're done. Highlights:

- `concurrencyPolicy: Forbid` — prevents pile-up if a run goes long.
- `activeDeadlineSeconds: 60` on realtime so a hung run doesn't block the next tick.
- `activeDeadlineSeconds: 1800` on consolidate to give it room for LLM consolidator work.

**Option C — in-process.** If your agent server is already a long-running process (FastAPI, axum, whatever), you can skip the external scheduler and run both cells from the same event loop. Python:

```python
import asyncio
from chunkshop.config import load_config
from chunkshop.runner import run_cell

async def memory_scheduler():
    while True:
        try:
            await asyncio.to_thread(run_cell,
                load_config("/etc/chunkshop/memory/realtime.yaml"))
        except Exception:
            logger.exception("realtime tick failed")
        await asyncio.sleep(60)

# In your app startup:
asyncio.create_task(memory_scheduler())
# (and another task with consolidate.yaml on a 3600s interval)
```

Full working example with FastAPI lifespan in [`docs/samples/memory-scheduling/in-process-python/run.py`](https://github.com/yonk-labs/chunkshop/tree/main/docs/samples/memory-scheduling/in-process-python).

Rust mirror at [`docs/samples/memory-scheduling/in-process-rust/main.rs`](https://github.com/yonk-labs/chunkshop/tree/main/docs/samples/memory-scheduling/in-process-rust).

Trade-off on the in-process pattern: easier ops (one binary, no second cron config), but a crash in your agent server now also stops your memory consolidation. For a hobby project or single-user agent, fine. For multi-user production, run the cells as separate processes.

## Step 5: Read it back

This is where you stop and decide what shape your reader takes. Three patterns I've actually used.

**Plain SQL.** The simplest thing. Your agent's "load context" step before each model call:

```python
import psycopg, os

def load_session_memory(session_id: str, k: int = 10) -> list[str]:
    sql = """
        SELECT original_content, recorded_at
        FROM agent_memory.memory
        WHERE doc_id = %s
          AND tier = 'consolidated'
          AND coalesce(retracted, false) = false
        ORDER BY recorded_at DESC
        LIMIT %s
    """
    with psycopg.connect(os.environ["CHUNKSHOP_MEMORY_DSN"]) as c, c.cursor() as cur:
        cur.execute(sql, (session_id, k))
        return [row[0] for row in cur.fetchall()]

# In your message handler:
mem = load_session_memory(session_id)
system_prompt = "Memory of prior turns:\n" + "\n".join(f"- {m}" for m in mem)
```

The two filters that matter: `tier = 'consolidated'` (the O2 rule from the design — prefer consolidated over provisional) and `coalesce(retracted, false) = false` (hide facts that have been contradicted by later turns).

**Vector search.** Same query plus a pgvector cosine similarity:

```sql
SELECT original_content, embedding <=> $1::vector AS dist
FROM agent_memory.memory
WHERE doc_id = $2
  AND tier = 'consolidated'
  AND coalesce(retracted, false) = false
ORDER BY embedding <=> $1::vector
LIMIT 10;
```

The embedding column is a pgvector type. The `<=>` operator is cosine distance. Use an `IVFFlat` or `HNSW` index in production (the realtime preset doesn't create one — add it once your table grows past ~10k rows).

**pg-raggraph bridge.** If you're already using pg-raggraph for retrieval, chunkshop ships a helper that hands the consolidated memory off in the exact shape pg-raggraph's `ingest_records()` accepts:

```python
from chunkshop.memory import read_pre_chunked

records = list(read_pre_chunked(os.environ["CHUNKSHOP_MEMORY_DSN"]))
# Each record has pre_chunked (episode chunks with embeddings),
# known_relationships (SPO triples), known_entities, skip_llm=True.
await rag.ingest_records(records, namespace="agent_memory")
```

End-to-end demo: [`docs/samples/memory-to-pgraggraph/`](https://github.com/yonk-labs/chunkshop/tree/main/docs/samples/memory-to-pgraggraph).

## Bonus step: an actual fact extractor

The default consolidator is extractive. Picks sentences for a summary, emits no structured facts. That works for "remember the gist of this conversation." For "extract who said what about which database" — wire an LLM consolidator.

In Python it's a callable named in your YAML:

```yaml
chunker:
  type: consolidation
  base:
    type: sentence_aware
    max_chars: 2000
  consolidator:
    mode: callable
    module: my_app.consolidators
    function: extract_with_claude
  fact_max_chars: 1200
```

```python
# my_app/consolidators.py
import anthropic, json

client = anthropic.Anthropic()

def extract_with_claude(episode: dict) -> dict:
    response = client.messages.create(
        model="claude-haiku-4-5-20251001",
        max_tokens=1024,
        system=(
            "Extract structured facts from this conversation episode. "
            "Return JSON: {summary, facts: [{subject, predicate, object, "
            "support_span, confidence}]}. Confidence is 0-1. Only emit facts "
            "with clear support in the text."),
        messages=[{"role": "user", "content": episode["text"]}])
    return json.loads(response.content[0].text)
```

A few things to notice. The episode text comes in as a single string — already role-tagged. The output schema is fixed (chunkshop expects exactly these keys). If your model returns malformed JSON or times out, raise — chunkshop catches it and falls back to emitting an episode chunk with no facts and a `consolidation_error` stamp in the metadata. One bad model call doesn't poison the nightly run.

I use Haiku for this — it's fast, cheap, structured output works fine. Sonnet would be overkill for fact extraction.

The Rust equivalent is a trait implementation:

```rust
use chunkshop::consolidators::{Consolidator, EpisodeInput, ConsolidationOutput, FactTriple};

pub struct ClaudeConsolidator { client: anthropic::Client }

impl Consolidator for ClaudeConsolidator {
    fn consolidate(&self, ep: &EpisodeInput<'_>) -> anyhow::Result<ConsolidationOutput> {
        // ... blocking_call_claude_extract returns the parsed JSON ...
        let parsed = blocking_call_claude_extract(ep.text)?;
        Ok(ConsolidationOutput {
            summary: parsed.summary,
            facts: parsed.facts.into_iter().map(|f| FactTriple {
                subject: f.subject, predicate: f.predicate, object: f.object,
                support_span: f.support_span, confidence: f.confidence,
            }).collect(),
        })
    }
    fn mode(&self) -> &'static str { "claude-haiku" }
}
```

You wire this once in your binary's startup — `ConsolidationChunker::new(base, Box::new(ClaudeConsolidator { ... }), fact_max_chars)`. No YAML reflection magic; this is Rust, the wiring is at compile time.

## What you'll see when it works

After a few turns of staging plus one consolidate run, your `agent_memory.memory` table looks like this:

```
SELECT tier, kind, count(*) FROM agent_memory.memory GROUP BY 1, 2;

 tier         | kind    | count
--------------+---------+-------
 consolidated | episode |     2
 consolidated | fact    |     7
(2 rows)
```

Two episodes (one per session), seven facts extracted across them. The episode rows have full chunk content + embeddings. The fact rows have populated subject/predicate/object columns and effective_from timestamps.

Run consolidate again with no new staged events — same count. (Idempotent — that's part of the contract.)

Stage a new turn that contradicts a prior fact ("we migrated off Redis last week"), run consolidate — the old fact's `retracted` column flips to true, `retracted_at` gets stamped, `effective_to` gets set to the new event's timestamp. The old fact stays in the table; it's just hidden by the default reader filter. Your audit log is the database itself.

## Things I wish someone had told me

A few practical notes from getting this into production:

**The realtime cell is cheap enough to run every 30 seconds if you want.** I default to 60 because it's a nicer cron cadence, but the embedder loads in milliseconds and the table writes are tiny. The bottleneck is going to be your model's response latency, not the memory cell.

**The consolidate cell's `min_age_seconds` matters more than you think.** Default is 3600 (one hour). It says "don't try to consolidate a session that has had activity in the last hour." If you set it to 0 you'll keep consolidating mid-conversation, which is fine semantically but wastes the LLM consolidator's tokens because the conversation isn't done yet.

**Don't share a single namespace across tenants.** The PK includes namespace specifically so different tenants don't collide. Use the user/tenant ID as the namespace, set it via `target.memory.namespace` in your YAML, and your multi-tenant story Just Works.

**Prune the staging table eventually.** Use `chunkshop.memory.prune_staging(dsn, older_than=...)` weekly. By default it only drops rows that have been consolidated, so you don't lose pending work. The staging table will otherwise grow forever, and while Postgres doesn't care, your backup costs will eventually.

## What I built it for vs what you might use it for

I built this because I was writing the same pattern in three different agent projects and got tired of it. If you're building a single-user agent for yourself, this might be more infrastructure than you need — a single jsonb column on a sessions table is fine.

If you're building anything that's multi-user, multi-session, going to live more than a month, and the agent needs to behave like it remembers people — this is the pattern. It composes with pgvector, it composes with pg-raggraph, it composes with whatever memory tool you're already using. The point is to give you a write-side and a schema you can trust.

Two YAMLs, one cron entry, one function call per turn. That's the whole API.

---

*Source repo: [github.com/yonk-labs/chunkshop](https://github.com/yonk-labs/chunkshop). Spec and architecture write-up in [docs/architecture/memory-sink.md](https://github.com/yonk-labs/chunkshop/blob/main/docs/architecture/memory-sink.md). Scheduling samples in [docs/samples/memory-scheduling/](https://github.com/yonk-labs/chunkshop/tree/main/docs/samples/memory-scheduling). If something blows up, file an issue — I want to know.*
