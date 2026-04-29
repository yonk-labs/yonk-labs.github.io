---
title: "Meet lede: The Thing You Reach for Before the LLM Call"
date: 2026-04-28
draft: false
tags: ["lede", "summarization", "rag", "python", "rust", "preprocessing"]
summary: "Sub-millisecond extractive summarization with byte-identical Python and Rust implementations. The preprocessor that sits in front of the LLM call and cuts tokens 40-94 percent."
---

The thing you reach for before the LLM call.

OK first an admission. The summary library you actually need probably isn't built around an LLM. I know, I know. Heresy in 2026. But hear me out.

A few months ago I was working on an off-prompt library, something that needed to send tool output to either a vector store or a markdown file and pass a reference plus a summary back to the LLM to reduce token usage. Digging into what was actually getting sent, I realized: wow, the details we're handing the LLM almost guarantee a callback for the full results anyway. There has to be a better way to pass the important facts. LLM calls to pre-process or summarize worked, but at the cost of seconds, which isn't acceptable on the hot path. So: extractive summarization.

It's not just my problem either. Modern AI apps push more text through more LLM calls than is healthy. Long prompts. Chunk-then-embed loops. Tool results that get summarized before they go back to the model. Every one of those calls is tokens spent and latency burned, on a hot path that does not need a frontier model.

The 2026 enterprise narrative around this is unanimous. Preprocessing in front of the model is a 40 to 94 percent cost lever depending on whose number you trust ([Maxim](https://www.getmaxim.ai/articles/reduce-llm-cost-and-latency-a-comprehensive-guide-for-2026/), [Morph](https://www.morphllm.com/llm-cost-optimization)). Strip the boilerplate, compress the input, hand a smaller prompt to the model. Real money saved.

Catch is, the libraries that actually do that preprocessing are mostly wrong for the job. Sumy and nltk are great but they pull a heavy dependency tree. rust-bert ships ONNX. The LLM-as-summarizer pattern returns different bytes every call. And nobody really gives you a single library that runs in both Python and Rust and produces the same output in both.

So I built lede.

It's small. Stdlib only on the default install. About 400 lines for the scorer. Runs in 0.42 milliseconds on the Python core path and 0.13 ms in Rust on the project's [10-corpus benchmark](https://github.com/yonk-labs/lede/blob/main/benchmarks/quality/matrix-2026-04-26.md). Same input gives the same output bytes, every call, on every machine, on every version that hasn't explicitly bumped the scorer. Apache-2.0.

That's the elevator pitch. The rest of this is the demo.

## The 30-second example

```python
from lede import summarize

text = open("long_doc.md").read()
r = summarize(text, max_length=500)
print(r.summary)
```

That's it. One call, sub-millisecond, default 500-character budget.

A real worked example. The Wikipedia paragraph on Apollo 11 is 945 characters:

> The Apollo 11 mission landed humans on the Moon for the first time. NASA launched the Saturn V rocket from Kennedy Space Center on July 16, 1969, carrying astronauts Neil Armstrong, Buzz Aldrin, and Michael Collins. Four days later, Armstrong and Aldrin descended to the lunar surface in the Eagle lunar module while Collins remained in lunar orbit aboard the Columbia command module. Armstrong became the first person to walk on the Moon at 02:56 UTC on July 21, 1969, declaring "That's one small step for a man, one giant leap for mankind." Aldrin joined him 19 minutes later. The astronauts spent 21 hours and 36 minutes on the lunar surface, collecting 21.5 kilograms of lunar material before returning to Columbia. The mission splashed down in the Pacific Ocean on July 24, 1969, completing an 8-day journey that fulfilled President Kennedy's 1961 goal of landing a man on the Moon and returning him safely to Earth before the decade ended.

`summarize(text, max_length=400)` returns:

> The Apollo 11 mission landed humans on the Moon for the first time. The mission splashed down in the Pacific Ocean on July 24, 1969, completing an 8-day journey that fulfilled President Kennedy's 1961 goal of landing a man on the Moon and returning him safely to Earth before the decade ended.

Topic sentence and the closing recap. The two sentences a real reader skims first when they're trying to figure out what this paragraph is about. Time for that result is around 0.15 ms (it's a smaller doc, so faster than the corpus median).

The summary is direct quotes from the source: never paraphrased, never made up, never invented. What you read is what was actually written.

Want the structured stuff pulled at the same time?

```python
r = summarize(text, max_length=400, attach=["stats", "metadata"])
r.metadata.dates    # ('1969', '1961')
```

Total time with both attachments: about 0.3 ms. There's a deeper post coming about why this matters for RAG.

## About that scoring thing

The score is a weighted blend. TF-IDF for term distinctiveness within the document. Position with a U-shape, where leads and recaps win (the old "don't bury the lede" prior, hence the project name). Length plateaus at 10 to 30 words to filter fragments and run-ons. Default weights are 60/25/15.

Then four heuristics on top, because pure TF-IDF is too dumb for structured documents. Skip headings. Boost cue phrases like "Resolution:" or "Key takeaway:" by +2.0. Reward sentences containing digits. Weight conclusion sections higher.

That's the whole algorithm. Read the source in `src/lede/tfidf.py` if you want the detail. About 400 lines. No model, no embeddings, no hidden state. The longer answer with all the tunable knobs lives in the [FAQ](https://github.com/yonk-labs/lede/blob/main/docs/FAQ.md).

## lede vs Sumy vs LLM, on the same input

Numbers. From the [10-corpus benchmark](https://github.com/yonk-labs/lede/blob/main/benchmarks/quality/matrix-2026-04-26.md), p50 across 10 real-world inputs (CRM notes, meeting minutes, news articles, legal opinions, support tickets, etc.):

| Method | Time per doc (p50) | Determinism | Cost per doc |
|---|---|---|---|
| lede (Rust, default) | 0.13 ms | byte-identical | $0 |
| lede (Python, default) | 0.42 ms | byte-identical | $0 |
| lede + all 5 attachments | 2.55 ms | byte-identical | $0 |
| Sumy LexRank | 13.35 ms | deterministic | $0 |
| Sumy TextRank | 12.55 ms | deterministic | $0 |
| LLM API call | 500 to 5000 ms | non-deterministic | ~$0.005 to $0.02 |

Honest framing on those Sumy numbers, because somebody (correctly) called me out for handwaving them. 10 to 15 ms per document is genuinely fine. For a one-off summarization on a single doc, you wouldn't notice. Sumy is great software. The lede speed advantage matters when you're summarizing in volume: ingestion pipelines that process millions of documents, real-time chunkers, hot-path preprocessing in front of every LLM call. At that scale, the 30x multiplier compounds: a job that takes 30 minutes on Sumy takes 1 minute on lede. A 99th-percentile latency budget with 50 ms of slack absorbs lede comfortably and chokes on Sumy.

If you're not in that volume regime, Sumy is fine. Use it. lede is the answer to a specific scaling problem.

The LLM gap is different. 500 to 5000 ms isn't fine at any volume. That's "rate limiting your customer experience" territory. Plus the cost: $0.005 to $0.02 per call on Claude 3.5 Sonnet (per [docs/comparison.md](https://github.com/yonk-labs/lede/blob/main/docs/comparison.md)). Run that across a million documents a month and you've got real bills. Run it across the same input twice and you get different output bytes, which means snapshot tests break, audit trails go fuzzy, and the answer to "why this sentence and not that one?" is "the model decided."

### A real worked example

From the support-ticket corpus in `benchmarks/corpus/support-ticket.txt`. 2378-character engineering ticket about an ingest job hanging after a version bump.

lede returns this in 0.45 ms:

> Ticket #44812. Ingest job hangs after upgrade to chunkshop 0.2.0. Reporter: jamie.l@acme.example. Priority: P2. We upgraded chunkshop from 0.1.6 to 0.2.0 last Friday and since then our nightly ingest job has been hanging indefinitely on the step between chunking and embedding. Resolution: Caused by default embedder precision change in 0.2.0 triggering a HuggingFace model download on a network-restricted batch node. Customer pre-seeding int8 weights on shared cache as a follow-up.

Hits the metadata header (ticket number, reporter, priority), the symptom, the root cause, the resolution. Verbatim quotes throughout.

Sumy LexRank returns this in 12.6 ms:

> If your ingest box has no outbound internet during nightly windows, a common setup for air-gapped batch nodes, the download hangs on the socket. Short term: add EMBEDDING_CACHE_DIR to your YAML pointing at a shared NFS path, run the model once on a box with egress, and the batch node will read from cache. Resolution: Caused by default embedder precision change in 0.2.0 triggering a HuggingFace model download on a network-restricted batch node.

Denser sentences but it lost the ticket header and picked one of the support engineer's workarounds rather than the reporter's actual symptom.

What an LLM produces (Claude 3.5 Sonnet, ~1500 ms, ~$0.005 per call):

> Ticket #44812 (P2) reported chunkshop 0.2.0's nightly ingest hanging between chunking and embedding due to a HuggingFace model download triggered by the new fastembed-onnx-int8 default embedder on an air-gapped node. Support proposed three fixes (cache-dir, fp32 pin, disable downloads); customer pinned fp32, disabled downloads, and pre-seeded int8 weights on shared NFS as a follow-up. Job completed in 19 min; closed.

Honestly the best summary on prose quality. The LLM fuses three workaround sentences into one phrase, names the actor (with "Support proposed"), and compresses the resolution into a single closing clause. Better English than either extractive option, honestly.

But this is the place I keep landing in: prose quality and pipeline-fit are different problems. The LLM's output is great for the human who reads the daily ticket digest. It's wrong for the deterministic index that powers the support team's search bar, because next month the model bumps and the bytes drift. lede's output is great for that index because the bytes don't drift, the cost is zero, and the latency fits in any timing budget.

Different jobs.

## What I reach for it for

There are a handful of places I'd actually reach for this in production.

The most obvious one is RAG-prep pipelines. Chunk → lede → embed. One call gives you the focused summary to embed plus the structured fields (dates, amounts, entities) for the metadata column. There's a deeper blog coming on this with a working Postgres schema.

Second one: MCP and agent middleware. When an agent calls a tool that returns 50 KB of JSON or scraped HTML, you don't want all of that going back into the context window. Drop a `clean_text` plus `summarize(max_length=500)` in front of the result. Costs about 0.4 ms. Saves the tool result from blowing the prompt budget. Saves you from a token spike on every tool call.

Third: triage. The workload I'm building toward myself. I have 50 internal docs and a question. Chunk-based RAG hands me five paragraphs about budgets with no sense of which doc *is* the budget doc. lede gives me a quick lede plus key facts at the document level in a couple of milliseconds. I can route the right docs to the heavier pipeline, or skip the LLM entirely and just open the right file.

## Install and use

```bash
pip install lede
```

Default install brings zero runtime dependencies. Stdlib only. There are optional extras when you want them:

```bash
pip install "lede[wordforms]"     # spelled-out numbers ("five thousand")
pip install "lede[yake]"          # YAKE statistical key-phrase ranking
pip install "lede[textrank]"      # graph-based extractive for long docs
pip install lede-spacy            # PERSON / ORG / GPE entities via spaCy
```

Rust:

```bash
cargo add lede                    # library
cargo install lede                # CLI binary
```

The Rust port produces byte-identical output to the Python implementation for every fixture in the corpus. The fixture walker enforces this on every CI push. If they diverge, the build breaks. That parity is the differentiator against every other Python summarization library.

Basic Python usage:

```python
from lede import summarize, extract_keyword, clean_text, strip_think

# Default summary
r = summarize(text, max_length=500)

# Summary plus structured enrichments. Sub-5 ms with all five attached.
r = summarize(
    text,
    max_length=500,
    attach=["stats", "outline", "metadata", "phrases", "correlated_facts"],
)
r.metadata.dates     # tuple of date strings
r.metadata.amounts   # tuple of dollar/numeric amounts
r.metadata.urls      # tuple of URLs
r.stats              # numeric facts with sentence context
r.outline            # section headings + key sentence per section

# Query-driven (different question, different entry point)
relevant = extract_keyword(text, "pricing budget competitor", num_sentences=3)

# Pre-clean before scoring
cleaned = clean_text(raw_email_or_markdown)
visible = strip_think(reasoning_model_output)
```

CLI:

```bash
lede long_doc.md
lede long_doc.md --mode keyword --keywords "pricing budget" --top 3
echo "<think>...</think>Real answer." | lede --mode strip_think
```

## What it's bad at

Everything that requires understanding meaning. lede is regex and TF-IDF; "Revenue grew 23%" and "Sales rose nearly a quarter" are different sentences with the same fact, and lede sees no connection. For domain-specific synonym handling (medical terminology, financial ticker resolution), you need NLP that understands semantics.

Also: lede only deletes. It never rewrites. If your reviewer wants prose paraphrased for clarity, redundant phrasing collapsed, ideas fused across sentences, you need an LLM downstream. Use lede in front of the LLM call as a preprocessor, not instead of it.

It's English-biased on the regex backend. The token regex assumes Latin script and the stopword list is 43 English function words. Other Latin-script languages work but get worse scoring. Non-Latin scripts need a different tokenizer.

And the regex backend can't do entity extraction. That's the spaCy companion's job. `Metadata.entities` stays empty until you `pip install lede-spacy` and import it.

## Where to go

The repo is at [github.com/yonk-labs/lede](https://github.com/yonk-labs/lede). Apache-2.0.

Docs:
- [README](https://github.com/yonk-labs/lede/blob/main/README.md) for install and quick start
- [FAQ](https://github.com/yonk-labs/lede/blob/main/docs/FAQ.md) for the longer "how does it pick sentences" answer
- [Comparison doc](https://github.com/yonk-labs/lede/blob/main/docs/comparison.md) for the full benchmarked side-by-side
- [Tutorial guide](https://github.com/yonk-labs/lede/blob/main/docs/guide.md) for a feature-by-feature walkthrough

The deep-dive blog on lede plus Postgres for hybrid RAG goes up next. That's the one with the working SQL.

Open an issue if you find a corner case. File a PR if you have a fix. And if you ship lede in production, I want to hear what you broke.
