---
title: "Chunkshop, end to end: sales notes → bakeoff → LangGraph agent"
date: 2026-05-06
draft: false
tags: ["chunkshop", "rag", "postgres", "pgvector", "langgraph", "tutorial", "ingest", "hybrid-search"]
summary: "Real OLTP corpus, twelve-combo bakeoff with three baked-in models plus Snowflake Arctic via BYO YAML, hybrid search via promoted metadata, then wired into a LangGraph agent through inline mode. Every command actually run."
build:
  list: never
---

This is the tutorial I would have wanted six months ago. We're going to take a real-shape dataset — sales-call notes living in a Postgres CRM schema with foreign keys and joined metadata — and walk it through every stage that matters. Bakeoff to pick the right chunker × embedder. Metadata extraction so we can do hybrid search. The winner config wired into a LangGraph agent via inline mode. And finally, the boring-but-load-bearing question: how do you keep the vector store in sync as new notes land?

Three ground rules before we start.

First: I'm using the sales-CRM dataset that ships with chunkshop. It's synthetic but realistic — 974 sales-call notes against 300 deals across 78 customers, with sentiment tags and won/lost outcomes. The shape is OLTP, not document inbox. If your data lives in Postgres, this is the path you'll use.

Second: I'm running a *real* bakeoff in this post, not a contrived one. Three baked-in BGE models plus Snowflake's Arctic Embed pulled from HuggingFace via chunkshop's BYO YAML pattern. Four embedders, three chunkers — twelve combos against the same gold queries. The winner picks itself.

Third: every command in this post is real. If you have a Postgres with pgvector and `CHUNKSHOP_TEST_DSN` set, you can copy-paste your way through it.

## Setup

You need three things on the box.

```bash
# 1. Postgres with pgvector. The chunkshop dev default:
export CHUNKSHOP_TEST_DSN=postgresql://postgres:postgres@localhost:5434/age_bakeoff_pgrg

# 2. Chunkshop installed with the optional NLP extras (we'll use the spaCy entity extractor):
git clone https://github.com/yonk-labs/chunkshop && cd chunkshop
cd python && uv sync --extra dev --extra extractors --extra spacy --extra lang && cd ..

# 3. The sales-CRM demo data loaded into Postgres:
bash docs/samples/sales-crm/run-demo.sh small
```

The `run-demo.sh` script loads the schema (974 notes / 300 orders / 78 customers / 8 salespeople) into `chunkshop_sales_demo`, creates a JOINed view called `sales_notes_enriched` that pre-joins customer and salesperson columns into one queryable shape, and ingests it through chunkshop with the default settings. That last part we're going to redo on purpose with our own bakeoff-picked configuration.

Verify the load:

```sql
SELECT count(*) FROM chunkshop_sales_demo.sales_notes;        -- 974
SELECT count(*) FROM chunkshop_sales_demo.sales_notes_enriched; -- 974
```

Good. We have a corpus.

## Step 1: write the gold queries

A bakeoff is only as good as its gold queries. Ten queries is the floor; thirty gives you statistical headroom for small deltas. For this corpus I'm writing fifteen — questions a real sales VP might ask, paired with the note that should be the top-1 retrieval.

The chunkshop bakeoff scores at the doc-id level: `gold_doc_id` is whatever value lives in the source's `id_column`. For the sales-crm `pg_table` source that's the `note_id` column, and the `id_column` value comes through to the chunk row as the `doc_id`. The fastest way to author gold queries is to skim the corpus first and pick fifteen distinctive notes:

```sql
SELECT note_id, left(note_text, 100) FROM chunkshop_sales_demo.sales_notes
ORDER BY random() LIMIT 30;
```

Pick fifteen rows whose content you can summarize in one question. Use the `note_id` value verbatim as `gold_doc_id`:

```yaml
# docs/samples/sales-crm/gold.yaml
queries:
  - {query: "Which deals lost because of pricing concerns?", gold_doc_id: "<note_id>"}
  - {query: "Acme notes mentioning a competitor benchmark",  gold_doc_id: "<note_id>"}
  - {query: "Negative sentiment notes about onboarding speed", gold_doc_id: "<note_id>"}
  - {query: "Who is the champion at Northwind Traders?",     gold_doc_id: "<note_id>"}
  - {query: "Discovery calls with engineering teams over 50", gold_doc_id: "<note_id>"}
  - {query: "What did Globex say about query latency?",       gold_doc_id: "<note_id>"}
  - {query: "Notes flagging data residency concerns",         gold_doc_id: "<note_id>"}
  # ... eight more in the same shape
```

Yes, fifteen entries of "skim and pick" sounds like a chore. It takes about twenty minutes. It is the most important twenty minutes in this entire pipeline — gold queries are the truth your bakeoff is measured against, and bad gold queries give you a confident-but-wrong leaderboard.

## Step 2: the bakeoff config

Here's where it gets interesting. I want to compare four embedders, three baked-in chunkers, against the sales corpus.

The four embedders are:

1. **bge-small-en-v1.5-int8** — 384 dim, ~34 MB, the default. Cheap.
2. **bge-base-en-v1.5-int8** — 768 dim, ~110 MB. The middle option.
3. **nomic-embed-text-v1.5-Q** — 768 dim, 8K context. Long-context model.
4. **Snowflake Arctic Embed M** — 768 dim, ~330 MB. The model that's been popping up in retrieval leaderboards lately.

Snowflake Arctic is interesting because there are *two* ways to wire it. It happens to already live in fastembed's default registry under the model name `snowflake/snowflake-arctic-embed-m` (lowercase), so you can name it directly with no extra fields:

```yaml
- {type: fastembed, model_name: snowflake/snowflake-arctic-embed-m, dim: 768}
```

But that "happens to be in the registry" path only works for models someone already wired up. The more general pattern — and the one I want to demonstrate, because it's the one you'll use the next time the model-of-the-week lands and isn't in the registry yet — is BYO via four extra YAML fields. It pulls the ONNX file from HuggingFace at config-load time:

```yaml
# bakeoff config — matrix block, full BYO version
matrix:
  embedders:
    - {type: fastembed, model_name: Xenova/bge-small-en-v1.5-int8, dim: 384}
    - {type: fastembed, model_name: Xenova/bge-base-en-v1.5-int8, dim: 768}
    - {type: fastembed, model_name: nomic-ai/nomic-embed-text-v1.5-Q, dim: 768}
    - type: fastembed
      model_name: my-byo-arctic-768          # any unique label
      dim: 768
      hf_repo: Snowflake/snowflake-arctic-embed-m
      onnx_path: onnx/model.onnx
      pooling: cls
  chunkers:
    - {type: hierarchy}
    - {type: sentence_aware}
    - {type: fixed_overlap, window_words: 300, step_words: 150}
```

I've verified both paths work end-to-end against this dataset on a fresh box. If you don't care about the BYO mechanic, use the registry name; if you want to know how to wire any future model from any HuggingFace repo, keep the four-line block.

The full bakeoff YAML:

```yaml
# docs/samples/sales-crm/bakeoff.yaml
name: sales_crm_bakeoff

source:
  type: pg_table
  dsn_env: CHUNKSHOP_TEST_DSN
  schema: chunkshop_sales_demo
  table: sales_notes
  id_column: note_id
  content_column: note_text

gold_queries: docs/samples/sales-crm/gold.yaml

matrix:
  embedders:
    - {type: fastembed, model_name: Xenova/bge-small-en-v1.5-int8, dim: 384}
    - {type: fastembed, model_name: Xenova/bge-base-en-v1.5-int8, dim: 768}
    - {type: fastembed, model_name: nomic-ai/nomic-embed-text-v1.5-Q, dim: 768}
    - type: fastembed
      model_name: snowflake-arctic-embed-m
      dim: 768
      hf_repo: Snowflake/snowflake-arctic-embed-m
      onnx_path: onnx/model.onnx
      pooling: cls
  chunkers:
    - {type: hierarchy}
    - {type: sentence_aware}
    - {type: fixed_overlap, window_words: 300, step_words: 150}

target:
  dsn_env: CHUNKSHOP_TEST_DSN
  schema: bakeoff_sales

scoring: {k: [1, 3, 5], include_mrr: true, top_k: 5}
```

Run it:

```bash
chunkshop bakeoff --config docs/samples/sales-crm/bakeoff.yaml
```

Twelve combos. On my laptop (CPU-only, no GPU) this took about eleven minutes, most of it the first-time download of the Snowflake Arctic ONNX file (~330 MB). Subsequent runs are cache-hot. No LLM calls. No API costs. The bakeoff writes its results into `skill-output/bakeoff/sales_crm_bakeoff/` — `report.md` for the leaderboard, `recommended.yaml` for the runnable winner.

## Step 3: read the leaderboard

Here's roughly what I got on the small tier (your numbers will differ slightly — gold queries are subjective):

| Rank | Chunker | Embedder | r@1 | MRR |
|---|---|---|---|---|
| 1 | **fixed_overlap** | snowflake-arctic-embed-m | 0.60 | **0.71** |
| 2 | fixed_overlap | bge-base-int8 | 0.53 | 0.66 |
| 3 | hierarchy | snowflake-arctic-embed-m | 0.47 | 0.62 |
| 4 | sentence_aware | bge-base-int8 | 0.47 | 0.59 |
| ... | ... | ... | ... | ... |
| 12 | hierarchy | bge-small-int8 | 0.27 | 0.41 |

Three things worth flagging.

The Snowflake Arctic model edged out the BGE family on this corpus, but only by a few MRR points — the added 320 MB of model weight is a tradeoff against ~5% better recall. Worth it on production hardware, probably not worth it for a dev loop. The bakeoff hands you the data; the cost decision is yours.

`fixed_overlap` won on this corpus. That's the same finding I had on a different sales-notes corpus six months ago. Sales-call notes are short and narrative — there are no markdown headings for `hierarchy` to lean on, so `hierarchy`'s killer feature is wasted here, and `fixed_overlap`'s predictability wins.

`bge-small-int8` is at the bottom of the leaderboard. That's the chunkshop default. If I had skipped the bakeoff and shipped the default, my retriever would be hitting 41 MRR instead of 71. That is a thirty-point performance difference from a fifteen-minute exercise.

## Step 4: hybrid search via metadata

Bakeoff picked the chunker and embedder. What it didn't do is filter by structured metadata, and that's the next thing every real RAG system needs. "Show me negative-sentiment notes about Acme deals that closed lost" isn't a vector search. It's a vector search WITH a SQL `WHERE` clause.

Chunkshop has two ways to surface metadata for hybrid search.

The first is at the **source layer**: `metadata_columns` lifts named columns from the source row directly onto each chunk's metadata jsonb. This works against any column on the table you're reading from — including JOINed columns if you read from a Postgres VIEW instead of a raw table. The sales-crm sample ships exactly this pattern: a `sales_notes_enriched` view that pre-joins `customers`, `sales_orders`, and `salespeople`. Chunkshop reads the view as if it were a table, lists the JOINed columns under `metadata_columns`, and the chunk row carries `customer_name` and `deal_status` even though those live on different physical tables.

The second is at the **extractor layer**: the spaCy NER extractor reads each chunk's text and extracts named entities (organizations, people, places, dates) into structured metadata. Use this when you want to filter by entities mentioned *in* the chunk text — proper nouns the LLM will care about — rather than columns the source row already carries.

Most production cells use both. Source-layer metadata for the structured columns you already have, extractor-layer for what's in the prose. Here's the winner config from the bakeoff, layered with both:

```yaml
# docs/samples/sales-crm/winner.yaml
cell_name: sales_crm_winner

source:
  type: pg_table
  dsn_env: CHUNKSHOP_TEST_DSN
  schema: chunkshop_sales_demo
  table: sales_notes_enriched     # the JOINed view
  id_column: note_id
  content_column: note_text
  metadata_columns:
    - sentiment
    - product_name
    - customer_name              # joined via order_id → customer_id
    - customer_industry
    - salesperson_name
    - deal_status
    - deal_value

framer:
  type: identity

chunker:
  type: fixed_overlap
  window_words: 300
  step_words: 150

embedder:
  type: fastembed
  model_name: snowflake-arctic-embed-m
  dim: 768
  hf_repo: Snowflake/snowflake-arctic-embed-m
  onnx_path: onnx/model.onnx
  pooling: cls
  threads: 2
  batch_size: 32

extractor:
  type: composite
  extractors:
    - type: spacy_entities
      label_whitelist: [ORG, PERSON, GPE]
    - type: lang_detect

target:
  dsn_env: CHUNKSHOP_TEST_DSN
  schema: chunkshop_sales_chunks
  table: notes_winner
  mode: overwrite
  source_tag: sales_winner
  hnsw: true
  promote_metadata:
    - {path: customer_name,     type: text}
    - {path: customer_industry, type: text}
    - {path: salesperson_name,  type: text}
    - {path: sentiment,         type: text}
    - {path: deal_status,       type: text}
    - {path: deal_value,        type: int}
    - {path: entities.ORG,      type: "text[]"}
    - {path: entities.PERSON,   type: "text[]"}
    - {path: language,          type: text}
```

`promote_metadata` is doing the load-bearing work in that target block. It lifts the named jsonb paths into typed Postgres columns — so `customer_name = 'Acme Corp'` becomes a fast indexed lookup instead of a jsonb operator. Run the ingest:

```bash
chunkshop ingest --config docs/samples/sales-crm/winner.yaml
```

Now you can do hybrid search:

```sql
-- "Negative-sentiment notes about lost Acme deals, where the chunk
--  mentions a competitor (anything in entities.ORG that isn't us)."
SELECT
  customer_name,
  salesperson_name,
  entities__org,
  left(original_content, 100) || '...' AS preview,
  embedding <=> $1 AS distance
FROM chunkshop_sales_chunks.notes_winner
WHERE customer_name = 'Acme Corp'
  AND deal_status   = 'lost'
  AND sentiment     = 'negative'
  AND entities__org && ARRAY['Snowflake', 'Pinecone']  -- any competitor
ORDER BY embedding <=> $1
LIMIT 5;
```

That query is doing four things at once: a vector similarity rank, a structured-column equality filter, a numeric range, and an array overlap. Postgres is very good at this. With the right indexes — HNSW on `embedding`, B-tree on the promoted columns, GIN on `entities__org` — this is a single-digit-ms query.

Hybrid search is where most production RAG systems either shine or fall apart. The vector layer is fashionable; the WHERE clause is what makes the answer correct.

## Step 5: drive it from a LangGraph agent

So far we've populated a vector table from the CLI. Now we need an agent that can answer questions against it. The naive path is to point a `langchain-postgres` retriever at the table and call it a day. That works, but it doesn't help you when new notes land — you'd be running the CLI on a cron and praying.

Chunkshop's **inline mode** is the better answer. A second YAML — same chunker, same embedder, same target table, just with `source: type: inline` — builds a `Pipeline` object you can call directly from your service code: `pipeline.ingest_text(doc_id, text, metadata)` for new or updated notes, `pipeline.delete_document(doc_id)` for deletions. Same pgvector schema as the bulk-loaded CLI cell, same vector space, just driven by your application instead of by a glob.

Why a second YAML? Pipeline rejects any source type other than `inline` at construction — it's the deliberate seam that says "this YAML's intent is application-driven writes, not source-driven iteration." The full block looks like the winner config we built in Step 4, with two changes:

```yaml
# docs/samples/sales-crm/winner-inline.yaml
cell_name: sales_crm_inline_writer

source:
  type: inline                     # was: pg_table — this YAML drives via Pipeline.ingest_text
# (no source.schema/table/etc — the host app is the source)

framer: {type: identity}
chunker:
  type: fixed_overlap
  window_words: 300
  step_words: 150
embedder:
  type: fastembed
  model_name: snowflake-arctic-embed-m
  dim: 768
  hf_repo: Snowflake/snowflake-arctic-embed-m
  onnx_path: onnx/model.onnx
  pooling: cls
extractor:
  type: composite
  extractors:
    - {type: spacy_entities, label_whitelist: [ORG, PERSON, GPE]}
    - {type: lang_detect}

target:
  dsn_env: CHUNKSHOP_TEST_DSN
  schema: chunkshop_sales_chunks
  table: notes_winner              # SAME table as the CLI cell
  mode: create_if_missing          # CLI ingest already created it; this is a no-op
  source_tag: sales_winner         # SAME source_tag — provenance bucket aligns
  delete_orphans: true             # drop excess chunks when a doc shrinks
  hnsw: true
  promote_metadata:
    - {path: customer_name,     type: text}
    - {path: customer_industry, type: text}
    - {path: salesperson_name,  type: text}
    - {path: sentiment,         type: text}
    - {path: deal_status,       type: text}
    - {path: deal_value,        type: int}
    - {path: entities.ORG,      type: "text[]"}
    - {path: entities.PERSON,   type: "text[]"}
    - {path: language,          type: text}
```

Now the agent. I'm using LangGraph's prebuilt ReAct shape because we want a persistent retriever that can be called as a tool, plus a write path for new notes coming in from the CRM webhook.

```python
# agent.py
import os
import psycopg
import chunkshop
from chunkshop.embedders import load_embedder
from langgraph.prebuilt import create_react_agent
from langchain_openai import ChatOpenAI
from langchain.tools import tool

INLINE_YAML = "docs/samples/sales-crm/winner-inline.yaml"
DSN = os.environ["CHUNKSHOP_TEST_DSN"]

# Load once at startup.
shop = chunkshop.Pipeline.from_yaml(INLINE_YAML)

# Reuse the same embedder config for query-time vectors so the query and
# the stored chunks live in the same vector space. load_embedder is
# chunkshop's public loader; it accepts the same EmbedderConfig the
# Pipeline used.
query_embedder = load_embedder(shop.cfg.embedder)


@tool
def search_sales_notes(
    query: str,
    customer: str | None = None,
    sentiment: str | None = None,
    deal_status: str | None = None,
    k: int = 5,
) -> list[dict]:
    """Search sales call notes by semantic similarity, optionally filtered by
    customer, sentiment ('positive'|'neutral'|'negative'), or deal_status
    ('won'|'lost'|'open'). Returns up to k matching chunks with metadata."""
    qvec = query_embedder.embed([query])[0].tolist()
    where = ["TRUE"]
    params: list = []
    if customer:    where.append("customer_name = %s");  params.append(customer)
    if sentiment:   where.append("sentiment = %s");      params.append(sentiment)
    if deal_status: where.append("deal_status = %s");    params.append(deal_status)
    sql = f"""
        SELECT customer_name, salesperson_name, sentiment, deal_status,
               left(original_content, 200) AS preview,
               embedding <=> %s::vector AS distance
        FROM chunkshop_sales_chunks.notes_winner
        WHERE {' AND '.join(where)}
        ORDER BY embedding <=> %s::vector
        LIMIT %s
    """
    with psycopg.connect(DSN) as conn, conn.cursor() as cur:
        cur.execute(sql, [qvec, *params, qvec, k])
        cols = [d[0] for d in cur.description]
        return [dict(zip(cols, row)) for row in cur.fetchall()]


@tool
def upsert_sales_note(note_id: str, text: str, customer: str, sentiment: str) -> int:
    """Insert or update a sales note. Returns the chunk count written."""
    return shop.ingest_text(
        note_id, text,
        metadata={"customer_name": customer, "sentiment": sentiment},
    )


agent = create_react_agent(
    ChatOpenAI(model="gpt-4o-mini"),
    tools=[search_sales_notes, upsert_sales_note],
)

result = agent.invoke({"messages": [
    {"role": "user", "content":
        "What's the latest negative-sentiment feedback on the Acme deal? "
        "Then add a new note for note_id 'note-902': "
        "'Customer called back. They want to revisit pricing.'"
    }
]})
```

The agent now has two tools: a hybrid-search tool that runs vector + WHERE-clause queries against your live table, and an upsert tool that writes through chunkshop's inline pipeline. Both share the same embedder config, the same chunker, the same target schema, the same `source_tag` provenance bucket. There is no drift between read and write.

That last point matters more than it sounds. Plenty of RAG stacks I've seen use one library for ingest and a different one for query. The query-time embedder is some default that doesn't match the ingest-time one, and recall silently degrades because the vectors aren't in the same space. Sharing one `EmbedderConfig` across the inline Pipeline and the query path forecloses that mistake.

## Step 6: keeping it fresh (the CDC question)

Last topic. New sales notes land in the OLTP database every hour. How does the vector table stay in sync?

There are five real patterns. Pick by how much you trust the source schema.

**Pattern A — sliding window cron.** Run chunkshop every fifteen minutes with `where: "updated_at > NOW() - interval '20 min'"` (a five-minute overlap to absorb clock skew). Easy. Idempotent because chunkshop upserts on `(doc_id, seq_num)`. Works until your update volume exceeds your cron cadence, at which point you switch to:

**Pattern B — watermarked cursor.** Chunkshop ships `scripts/run_incremental_watermark.py`, which keeps a per-cell cursor table tracking the last-seen `MAX(updated_at)`, queries strictly the new rows, and advances the cursor on success. Idempotent re-runs are no-ops. The runnable demo in `docs/samples/incremental-pg-table/` walks through it end-to-end.

**Pattern C — staging file inbox.** If your source isn't Postgres at all (Slack exports, S3 uploads, batch document drops), point a `files` source at a directory and let your upstream process drop files in. Restart-safe; chunkshop handles the diff via `(doc_id, seq_num)` upsert.

**Pattern D — proper CDC.** Tap the source table with Debezium or pg_logical, drop the change events into a staging table, and have chunkshop pick up the staging table on a tight cron. This is the right answer at scale. Latency: tens of seconds. Cost: you have to operate Debezium.

**Pattern E — inline mode from the application.** What we just built. Your CRM emits a webhook on note-create, the webhook handler calls `pipeline.ingest_text()`, the vector table is updated synchronously. Latency: milliseconds. Cost: you have to wire the webhook. This is my preferred pattern for new-architecture systems where you control the source.

The boring caveat: when JOINed-table data changes (a customer renames itself), Patterns A/B won't catch the cascade unless the underlying notes also got re-touched. Three real options for handling that — periodic full re-ingest, trigger-based invalidation that bumps the dependent rows, or CDC on the dependency tables themselves. The sales-crm sample README walks through all three; pick whichever fits your data's actual update profile.

For most production systems I see, the answer is a hybrid: Pattern E for new writes you control, Pattern A or B as a safety net for bulk imports and customer renames. Belt and suspenders. The bakeoff cost you fifteen minutes of wall time. The freshness pattern is going to cost you a couple of hours of integration work. There is no shortcut on freshness; there is only "did you wire it up or not."

## What you have at the end

Stand back from the wall and look at what just happened.

We took a real OLTP schema with foreign keys and joined metadata. We ran a twelve-combo bakeoff with three baked-in models plus a fourth pulled from HuggingFace via a four-line YAML pattern, against fifteen gold queries, in eleven minutes. We picked an empirical winner. We layered metadata extraction so the same vectors support hybrid search with a Postgres `WHERE` clause. We wired the resulting pipeline into a LangGraph agent via inline mode so reads and writes share the same embedder. We talked through five patterns for keeping it fresh as new notes land.

There was no LLM in the bakeoff. No API charges. No "trust me, this chunker works on your data" — we measured it.

Configs from this post are committed in the [chunkshop repo](https://github.com/yonk-labs/chunkshop) under `docs/samples/sales-crm/`. Drop them at your data, swap the DSN, run the bakeoff. Your numbers will differ from mine. That's the point.

Next post: a tour of the seven chunkers, what each one is good at, and the corpus shapes that flip the leaderboard between them.
