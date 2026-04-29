---
title: "Three Signals Beat One: Hybrid RAG with lede and Postgres"
date: 2026-04-29
draft: false
tags: ["lede", "rag", "postgres", "pgvector", "hybrid-search", "summarization"]
summary: "Most production RAG pipelines run on one signal: chunks. Add doc-level summaries plus structured metadata in Postgres and you get three signals — with working SQL at the bottom of the post."
---

Hot take to start: most production RAG pipelines I look at are running on one signal. Chunks. That's the problem.

The standard pipeline goes like this. Document in. Chunked into 500-token windows. Each chunk embedded. Embeddings into pgvector or Pinecone or whatever. At query time, embed the question, do nearest-neighbor search, return top-k chunks, stuff them into the prompt, hand to the LLM. Done.

It works. It's also leaving real signal on the floor.

What's missing is the *document*. When a chunk is "Q3 revenue grew 23% year-over-year to $12M," your retrieval has to figure out from those 60 characters whether this is the budget doc, the earnings doc, the board minutes, or somebody's blog. The chunk doesn't say. The chunk's embedding doesn't say either. You search for "revenue growth" and get five paragraphs about budgets with no sense of which document *is* the budget doc.

So you reach for the LLM. Top 20 chunks plus a long system prompt and pray it figures out the right framing. Bigger models, longer prompts, more tokens, slower responses, larger bills. Same architecture as five years ago, just more expensive.

I've been living this for the last three months. Burning tokens like mad. It's shocking how often Claude or Codex put me in virtual time-out, and I've been feeding money into overage charges on top of that. The more I looked at where it was going, the more I realized how much I was throwing away on silly things. I looked at [caveman](https://github.com/juliusbrussee/caveman) (which is very cool if you haven't seen it) but I wanted something smaller and more predictable.

There's a better answer. The summary is the missing signal.

Working SQL at the bottom of this post if you want to skip there. The buildup is about why summarization quality is the thing most RAG retrievers are getting wrong, and how lede plus Postgres gets it right.

## Accuracy in RAG isn't about prose

When most people say "accurate summary," they mean readable prose that captures the gist. That's a great metric for human readers. Wrong metric for RAG.

Three different things, actually. Fact preservation is the obvious one. If the source says "$12M ARR in 2025" and your summary says "around $10M last year," every downstream filter that uses that number is now broken. Paraphrase loses precision, and precision is the whole reason you're piping the summary to a database column instead of a human reader.

The second one is provenance, and it's the part legal cares about. Every claim in the summary needs to appear verbatim somewhere in the source. When somebody asks "where did this number come from," you grep the doc and find the exact sentence. The LLM equivalent answer is "the model wrote it," and I've watched that answer fail compliance review more than once.

Then there's the determinism story. Same input has to give the same summary, every time, across versions and machines. That's how snapshot tests work. That's how you regression-test a retrieval pipeline against a known-good corpus. LLM summaries drift between model versions, and your test harness has no way to know.

LLMs do prose better. They fuse ideas, drop redundancy, produce something more readable than the source. Great for the user-facing summary at the end of the pipeline. Wrong tool for the preprocessor that has to feed a deterministic retrieval index.

Extractive summarization (which is what lede does) gives you all three properties for free. Direct quotes from the source. Same bytes every run. Every claim is a sentence in the document, not a paraphrase the model invented. Less prose-y output. Actually correct.

That's the reason classical extractive is interesting again. Not because it beats LLMs on quality. It doesn't. It beats them on the four properties (cost, latency, determinism, provenance) that an audit chain actually needs.

## What lede pulls out of a document

Most people stop at "lede produces a summary." Headline feature. The deeper value is the structured fact extraction that ships in the same call.

Below is a synthetic press release. Made up, illustrative, do not Google these companies:

> Acme Corp announced today a $40M Series C led by Hyperion Ventures. The round, closed on March 15, 2026, brings Acme's total raised to $87M and values the company at $420M. CEO Maria Reyes said the funds will accelerate hiring, with plans to grow engineering from 45 to 110 by end of 2026, and to open new offices in London and Singapore. Acme's revenue grew 230% year-over-year in 2025, reaching $12M ARR.

Run it through lede with all attachments:

```python
from lede import summarize
import lede_spacy  # registers the spacy backend for entities

r = summarize(
    text,
    max_length=300,
    attach=["stats", "metadata", "phrases", "correlated_facts"],
    backend="auto",
)
```

What you get back (illustrative output for this synthetic input):

```python
r.summary
# 'Acme Corp announced today a $40M Series C led by Hyperion Ventures.
#  The round, closed on March 15, 2026, brings Acme's total raised to
#  $87M and values the company at $420M.'

r.metadata.dates       # ('March 15, 2026', '2026', '2025')
r.metadata.amounts     # ('$40M', '$87M', '$420M', '$12M')
r.metadata.entities    # ('Acme Corp', 'Hyperion Ventures', 'Maria Reyes',
                       #  'London', 'Singapore')
                       # (entities populated only with backend="spacy" or "auto")

r.stats
# (Stat(value='230', unit='percent', stat_type='percent', ...),
#  Stat(value='45', unit=None, stat_type='count', ...),
#  Stat(value='110', unit=None, stat_type='count', ...))

r.correlated_facts
# (PhraseFact(entity='engineering', number='45', polarity='neutral'),
#  PhraseFact(entity='engineering', number='110', polarity='increase'),
#  PhraseFact(entity='revenue', number='230%', polarity='increase'))
```

Total time for all of that on a real measured input is around 2.5 ms p50 (per the [10-corpus benchmark](https://github.com/yonk-labs/lede/blob/main/benchmarks/quality/matrix-2026-04-26.md), with all five attachments). One input text. No additional API calls, no second pass, no separate NER service.

Now look at what just happened. You got the summary, sure, but you also got a structured doc-level signal that didn't exist before. Dates that range-filter naturally. Dollar amounts that sort and aggregate. Entities that can join against a customer table when you have one. Stats that roll up across documents. And the correlated_facts field, which is the one I find myself using most for "did revenue go up or down" questions where the polarity matters.

This is the part the standard chunk-only RAG architecture loses. When you embed a chunk and search by vector similarity, you can find passages that are semantically near a query. You cannot easily filter to "documents from Q1 2026 that mention Goldman Sachs." That's a join, on structured fields, not a vector search.

So extract those structured fields. Put them in Postgres alongside the embedding. Use both at query time. Hybrid search.

## The schema

Two tables. Documents at the top, chunks underneath.

```sql
CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE documents (
    doc_id          BIGSERIAL PRIMARY KEY,
    source_url      TEXT,
    raw_text        TEXT NOT NULL,
    summary         TEXT NOT NULL,
    summary_embed   vector(384),
    metadata        JSONB NOT NULL DEFAULT '{}',
    fact_pairs      JSONB NOT NULL DEFAULT '[]',
    summary_tsv     tsvector
                    GENERATED ALWAYS AS (to_tsvector('english', summary))
                    STORED,
    ingested_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_doc_summary_embed
    ON documents USING hnsw (summary_embed vector_cosine_ops);
CREATE INDEX idx_doc_metadata_gin
    ON documents USING gin (metadata jsonb_path_ops);
CREATE INDEX idx_doc_summary_tsv
    ON documents USING gin (summary_tsv);
CREATE INDEX idx_doc_ingested_at
    ON documents (ingested_at DESC);

CREATE TABLE chunks (
    chunk_id        BIGSERIAL PRIMARY KEY,
    doc_id          BIGINT NOT NULL
                    REFERENCES documents(doc_id) ON DELETE CASCADE,
    chunk_idx       INT NOT NULL,
    chunk_text      TEXT NOT NULL,
    chunk_embed     vector(384) NOT NULL
);

CREATE INDEX idx_chunks_embed
    ON chunks USING hnsw (chunk_embed vector_cosine_ops);
CREATE INDEX idx_chunks_doc_idx
    ON chunks (doc_id, chunk_idx);
```

Three indexes on the `documents` table is the point. Each indexes a different signal:
- `idx_doc_summary_embed`: vector similarity. Find docs whose *summary* is semantically near the query.
- `idx_doc_metadata_gin`: structured filters. Find docs that mention specific entities, fall in date ranges, or contain dollar amounts.
- `idx_doc_summary_tsv`: full-text search. Find docs whose summary contains specific phrases.

The chunks table is standard. Chunks are the passage-level signal. They live alongside the doc-level signal but they're not the only thing you search.

Important note: the SQL above is reference. It's not deployed in lede itself or part of any test suite. You'll tune the dimensionality (384 is the `all-MiniLM-L6-v2` default; swap as needed), the HNSW parameters, and the index types based on your actual workload. Treat this as a starting schema, not a blueprint.

## Ingestion in one pass

```python
import json
from sentence_transformers import SentenceTransformer
from lede import summarize
import lede_spacy  # registers the spacy entity backend
import psycopg2

embed_model = SentenceTransformer("all-MiniLM-L6-v2")  # 384-dim
conn = psycopg2.connect(...)


def ingest(raw_text: str, source_url: str | None = None) -> int:
    # 1. lede on the full document. ~2.5 ms p50 with all attachments.
    r = summarize(
        raw_text,
        max_length=500,
        attach=["stats", "outline", "metadata", "phrases", "correlated_facts"],
        backend="auto",
    )

    # 2. Embed the summary, not the full doc.
    #    The summary is the most informative sentences by construction.
    #    Embedding a 500-char focused summary is cheaper and more focused
    #    than embedding 50,000 chars of mixed content.
    summary_vec = embed_model.encode(r.summary).tolist()

    # 3. Pack metadata into JSONB. This is the STRUCTURED signal.
    metadata = {
        "source_url": source_url,
        "dates": list(r.metadata.dates),
        "amounts": list(r.metadata.amounts),
        "urls": list(r.metadata.urls),
        "entities": list(r.metadata.entities),
        "phrases": list(r.phrases),
        "outline": [s._asdict() for s in r.outline],
        "stats": [s.__dict__ for s in r.stats],
    }
    fact_pairs = [pf.__dict__ for pf in r.correlated_facts]

    cur = conn.cursor()
    cur.execute("""
        INSERT INTO documents
            (source_url, raw_text, summary, summary_embed, metadata, fact_pairs)
        VALUES (%s, %s, %s, %s, %s, %s)
        RETURNING doc_id
    """, (
        source_url, raw_text, r.summary, summary_vec,
        json.dumps(metadata), json.dumps(fact_pairs),
    ))
    doc_id = cur.fetchone()[0]

    # 4. Chunk the raw doc using your existing chunker.
    chunks = chunk_paragraphs(raw_text, target_size=400)
    for idx, chunk_text in enumerate(chunks):
        chunk_vec = embed_model.encode(chunk_text).tolist()
        cur.execute("""
            INSERT INTO chunks (doc_id, chunk_idx, chunk_text, chunk_embed)
            VALUES (%s, %s, %s, %s)
        """, (doc_id, idx, chunk_text, chunk_vec))

    conn.commit()
    return doc_id
```

The lede call itself adds about 2.5 ms per document on top of whatever your chunker plus embedder already costs. The extra embedding (one round trip per doc to embed the summary) is the bigger overhead, and it depends on whether you're calling a local model or a hosted API. On a hosted API at 50 ms per call, you're adding one call's worth of latency per document. If that's the dominant cost in your ingestion budget, batch the summary embeddings.

Worth it for what you get back: a doc-level summary, a doc-level embedding, structured metadata in JSONB, full-text search on the summary, and entity-level fact pairs. All searchable from the same database.

## The hybrid query

This is where the schema pays off. Here's what chunk-only RAG looks like:

```sql
SELECT chunk_id, chunk_text, doc_id,
       1 - (chunk_embed <=> $1::vector) AS sim
FROM chunks
ORDER BY chunk_embed <=> $1::vector
LIMIT 20;
```

One signal. Vector similarity on chunk embeddings. Returns the 20 nearest chunks regardless of which document they came from.

Hybrid search with the lede schema looks like this:

```sql
WITH q_vec AS (
    SELECT $1::vector(384) AS v
),
-- Doc-level pre-filter: which documents are even relevant?
doc_candidates AS (
    SELECT
        d.doc_id,
        d.summary,
        d.metadata,
        1 - (d.summary_embed <=> (SELECT v FROM q_vec)) AS summary_sim,
        ts_rank(d.summary_tsv, plainto_tsquery('english', $2)) AS lex_rank
    FROM documents d
    WHERE
        -- Optional structured filter from JSONB.
        d.metadata @> $3::jsonb
        AND (
            -- Either the summary is semantically near...
            d.summary_embed <=> (SELECT v FROM q_vec) < 0.6
            -- ...or the summary lexically matches.
            OR d.summary_tsv @@ plainto_tsquery('english', $2)
        )
    ORDER BY d.summary_embed <=> (SELECT v FROM q_vec)
    LIMIT 100
),
-- Chunk-level retrieval, but only from candidate docs.
chunk_hits AS (
    SELECT
        c.doc_id,
        c.chunk_id,
        c.chunk_text,
        1 - (c.chunk_embed <=> (SELECT v FROM q_vec)) AS chunk_sim
    FROM chunks c
    WHERE c.doc_id IN (SELECT doc_id FROM doc_candidates)
    ORDER BY c.chunk_embed <=> (SELECT v FROM q_vec)
    LIMIT 50
)
-- Combine signals into a hybrid score.
SELECT
    ch.doc_id,
    ch.chunk_id,
    ch.chunk_text,
    dc.summary,
    dc.metadata,
    ch.chunk_sim,
    dc.summary_sim,
    dc.lex_rank,
    -- Weighted hybrid score. Tune to your eval set.
    0.55 * ch.chunk_sim
  + 0.30 * dc.summary_sim
  + 0.15 * dc.lex_rank
        AS hybrid_score
FROM chunk_hits ch
JOIN doc_candidates dc ON ch.doc_id = dc.doc_id
ORDER BY hybrid_score DESC
LIMIT 20;
```

A few things this query is doing that the chunk-only version can't.

First, it narrows the search space at the doc level before it ever scores chunks. Vector similarity on the summary plus lexical match on the full-text index gives you a candidate set of around 100 documents. Chunks only get scored inside that set. On a 10-million-chunk corpus that's a real efficiency win.

Then there's the structured filter, which is honestly the part LLMs can't help you with. `d.metadata @> $3::jsonb` lets the caller pass arbitrary JSONB filters. Need only docs that mention Goldman Sachs? Pass `{"entities": ["Goldman Sachs"]}`. Need only docs with a 2026 date in metadata? Pass `{"dates": ["2026"]}`. The GIN index makes this cheap, which matters because you'll do it on every query.

Last, the actual ranking. Three components combined: chunk-level vector similarity gets the most weight because passage precision matters most for the LLM's context window. Doc-level summary similarity gets the middle weight because it captures the larger framing. Lexical match on the summary gets the lowest weight because it's brittle but it catches the cases where the user typed a specific phrase that semantic search missed. The weights I have here (0.55 / 0.30 / 0.15) are starter values. Tune them against your own eval set.

## A real query, two architectures

Take a query like: "How did Acme's funding rounds compare to their revenue growth in 2025?"

Chunk-only:

The query embedder turns the question into a vector. Vector search returns the 20 nearest chunks across the entire corpus. Some might be from the Acme press release. Some might be from completely unrelated documents that happen to talk about funding rounds. The LLM downstream gets a mix and has to figure out which context applies. Token bill goes up. Answer quality goes down.

Hybrid with lede plus Postgres:

```python
filter_clause = json.dumps({"entities": ["Acme"], "dates": ["2025"]})
results = run_hybrid_query(
    query="funding rounds and revenue growth",
    query_vec=embed_model.encode("funding rounds and revenue growth"),
    metadata_filter=filter_clause,
)
```

Postgres pre-filters to documents that mention Acme AND contain a 2025 date. Then it ranks chunks within those documents by vector similarity. The LLM downstream gets focused context: chunks from the right doc, with the doc-level summary attached so the model has the framing.

You went from "the LLM has to figure out which doc is relevant from chunk fragments" to "the LLM gets the right chunks plus the doc summary, already filtered." Same retrieval database. Fundamentally different retrieval quality.

## A second use case: doc routing

There's another workload worth calling out. Sometimes you don't want chunks at all. You want to figure out which documents are worth reading.

Picture a knowledge worker with 50 internal docs and a question. They don't want a one-sentence answer from an LLM. They want to know which 5 docs to actually read. The deep stuff lives in the docs themselves; the LLM is going to lose nuance no matter how well you prompt it.

For that workload, chunk-based RAG is wrong. You want doc-level routing.

```sql
SELECT
    doc_id,
    summary,
    1 - (summary_embed <=> $1::vector) AS sim,
    metadata->'entities' AS entities,
    metadata->'amounts' AS amounts,
    metadata->'dates' AS dates
FROM documents
WHERE 1 - (summary_embed <=> $1::vector) > 0.5
ORDER BY summary_embed <=> $1::vector
LIMIT 5;
```

Five docs ranked by doc-level summary similarity. Each result row gives the user the summary, the entities, the dollar amounts, the dates. The user picks two and clicks through to the raw documents. The LLM was never in the loop.

This is the workload I'm actually building toward myself. Not "answer the question." Find the documents. The LLM-as-summarizer pattern is wrong for that, because you don't want a paraphrase of what the doc says. You want a fast, fact-preserving signal that helps a human pick which doc to read.

## Practical notes

Some things I've tripped over while wiring this up.

Embed the summary, not the full doc. Embedding the full document is expensive (lots of tokens through your embedding model) and noisy (the embedding has to capture everything in the doc, which means it captures nothing well). The summary is the most informative sentences by construction; the embedding inherits that focus.

The metadata column stays as a single JSONB rather than separate columns for dates, amounts, and entities. Schema flexibility matters (lede might add fields between versions and you don't want a migration every time). Plus JSONB GIN indexing is genuinely fast for the kind of queries you'll write. Got a fixed query pattern that's hot? Denormalize that one field into its own column. Otherwise JSONB is fine.

Re-ingestion is reproducible because everything is derived from the source. If the source changes, re-run lede and re-embed. The pipeline is deterministic, so the same source gets you the same summary, metadata, and embedding next year as it does today. No part of this depends on a model version that might drift.

A note on cross-runtime work: lede's regex backend is byte-identical across Python and Rust. If you ingest from a Python pipeline and want to verify correctness from a Rust service, the same input produces the same summary and metadata. The spaCy backend is Python-only though, so entities populated from spaCy stay in the Python tier. Mixed-runtime ingestion needs that footnote.

Audit trails are clean by construction. Every sentence in the summary is a verbatim quote from the source. If a downstream user disputes a fact, the chain is chunk → doc → summary → source sentence. End-to-end provenance. No paraphrase, no hallucination, no "the model decided."

## What this isn't

A few honest limits, because the framing matters.

lede plus Postgres is the right tool when you're doing doc-level routing, when structured filters (entities, dates, amounts) are part of how users actually search, when every claim needs an audit trail back to a source sentence, and when your latency budget can't absorb 500 to 5000 ms of LLM preprocessing on every retrieval.

It's the wrong tool for cross-document reasoning. A query like "summarize the differences between these three earnings calls" still wants an LLM, because that's a synthesis problem, not a retrieval problem. It's also wrong for synonym handling: "MI" and "myocardial infarction" are different strings to lede, and the entity field won't merge them. A domain ontology goes in front of the metadata layer if you need that. And it's wrong for the final user-facing prose. The extractive summary is for the index, not the human reader. The user-facing answer should still come from an LLM with the lede-prepared context as input.

The pattern is lede in front of the LLM, not lede instead of it. Preprocessing layer that cuts input tokens 40 to 94 percent depending on corpus, plus the structured fields the LLM would otherwise have to be prompted to extract.

## Closing

Last thing, then I'll shut up. Chunk-only RAG is one signal. Hybrid RAG with lede plus Postgres gets you three: vector similarity on chunks for passage-level retrieval, vector similarity on summaries for doc-level retrieval, structured metadata for filters and routing. Plus a full-text fallback for when users type specific phrases that semantic search misses.

Three signals beat one. Most production RAG implementations are still on one. That's the gap.

The library is at [github.com/yonk-labs/lede](https://github.com/yonk-labs/lede). Apache-2.0. Python and Rust.

The schemas in this post are reference, not deployed code. You'll tune the dimensions, the HNSW parameters, the query weights, the candidate set size. Run an eval set. Watch which knobs move recall and precision. Lock the numbers when they stop moving.

If you ship this in production and want to compare notes, find me. I want to hear what worked and what didn't. Especially the cases where the metadata extraction missed something interesting. Those are the corpus failures that make the next release of lede better.

The hard problem is data engineering, not database selection. RAG accuracy was always going to come from preprocessing, not from bigger models.
