---
title: "lede"
date: 2026-04-28
draft: false
tags: ["python", "rust", "summarization", "rag", "preprocessing", "tf-idf"]
summary: "Sub-millisecond extractive summarization with byte-identical Python and Rust implementations. The preprocessor that sits in front of the LLM call."
externalUrl: "https://github.com/yonk-labs/lede"
---

**lede** is the thing you reach for *before* the LLM call. A small, fast, deterministic extractive summarizer with byte-identical Python and Rust implementations — built to cut input tokens 40-94% on hot-path preprocessing in front of LLM and embedding calls.

## Why lede?

- **Sub-millisecond latency** — 0.42 ms (Python) / 0.13 ms (Rust) p50 on the 10-corpus benchmark. Fits in any latency budget.
- **Byte-identical across runtimes** — same input produces the same output bytes in Python and Rust. CI enforces it on every push.
- **Direct quotes, never paraphrase** — every sentence in the summary appears verbatim in the source. Clean audit trail by construction.
- **Stdlib only on the default install** — no heavy dependency tree, no ONNX, no model downloads. About 400 lines for the scorer.
- **Structured fact extraction in the same call** — dates, amounts, URLs, entities, stats, and correlated facts available as one summarize call.
- **Apache-2.0** — use it anywhere.

## What it's for

- **RAG-prep pipelines** — chunk → lede → embed. Focused summaries to embed plus structured fields for the metadata column.
- **MCP and agent middleware** — stop tool results from blowing the context window. ~0.4 ms per call vs. 500-5000 ms LLM preprocessing.
- **Document routing** — find the right docs to read instead of asking an LLM to paraphrase them.
- **Hot-path preprocessing** — anywhere you'd send text through an LLM "just to summarize it." That's the wrong tool.

## How it scores

Weighted blend of TF-IDF for term distinctiveness, U-shape position scoring (leads and recaps win — hence the project name), and length plateaus to filter fragments and run-ons. Plus four structural heuristics: skip headings, boost cue phrases, reward sentences with digits, weight conclusion sections higher. Read the source in `src/lede/tfidf.py`.

## Tech Stack

- **Languages:** Python (stdlib only on default install) and Rust
- **Optional extras:** `lede[wordforms]`, `lede[yake]`, `lede[textrank]`, and `lede-spacy` for entity extraction

## Quick Start

```bash
pip install lede
```

```python
from lede import summarize

r = summarize(text, max_length=500)
print(r.summary)

# With structured enrichments — sub-5 ms with all five attached:
r = summarize(
    text,
    max_length=500,
    attach=["stats", "outline", "metadata", "phrases", "correlated_facts"],
)
r.metadata.dates     # tuple of date strings
r.metadata.amounts   # tuple of dollar/numeric amounts
r.metadata.entities  # tuple of named entities (with lede-spacy installed)
```

Rust:

```bash
cargo add lede                    # library
cargo install lede                # CLI binary
```

## Links

- [GitHub Repository](https://github.com/yonk-labs/lede)
- [README](https://github.com/yonk-labs/lede/blob/main/README.md)
- [FAQ](https://github.com/yonk-labs/lede/blob/main/docs/FAQ.md)
- [Comparison doc](https://github.com/yonk-labs/lede/blob/main/docs/comparison.md)
- [10-corpus benchmark](https://github.com/yonk-labs/lede/blob/main/benchmarks/quality/matrix-2026-04-26.md)
- License: Apache 2.0
