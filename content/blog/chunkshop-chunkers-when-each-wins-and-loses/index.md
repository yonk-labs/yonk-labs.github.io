---
title: "A field guide to the seven chunkers, and where each one falls over"
date: 2026-05-04
draft: false
tags: ["chunkshop", "rag", "chunking", "embeddings", "pgvector", "postgres"]
summary: "Seven walkthroughs with opinions — what each chunker is good at, where it falls over, and the corpus shape that flips the leaderboard between them. A field guide, not a recommendation. Bakeoff first."
build:
  list: never
---

There are about a hundred ways to chop a document into chunks. Chunkshop ships seven of them. This is the part where I tell you what each one is good at, where it falls over, and the corpus shape that breaks the leaderboard between them. Treat this as a field guide — not a recommendation. You don't pick a chunker from a blog post. You bakeoff, and the bakeoff tells you. (We covered that in [the tutorial post](../chunkshop-tutorial-sales-crm-bakeoff-to-langgraph/). Read that first if you skipped it.)

But — and this is the unspoken rule — you can't intelligently bakeoff if you don't understand what each chunker is *trying* to do. So: seven walkthroughs, with opinions.

## The five-minute mental model

Chunkers split into three families.

The **structural** chunkers (`sentence_aware`, `hierarchy`, `fixed_overlap`, `neighbor_expand`) split on syntactic cues — paragraphs, markdown headings, word counts. Fast, deterministic, identical output across runs.

The **semantic** chunker (`semantic`) splits on meaning drift via a small embedding model. Use when your source has no syntactic cues to lean on.

The **summary-layer** chunkers (`summary_embed`, `hierarchical_summary`) wrap any base chunker and change *what gets embedded* without changing what gets stored. The base chunker still does the cutting; the summary layer changes the vector.

Pick exactly one chunker per cell. Structural and semantic chunkers can be wrapped by `neighbor_expand`. Summary-layer chunkers wrap any base chunker in their own config block.

That's the map. Now the seven.

## 1. `sentence_aware` — paragraph-respecting prose splitter

**What it does.** Takes prose, walks paragraph boundaries, packs paragraphs together until it hits `max_chars`, hard-splits at sentence then character boundaries if a paragraph is too big to fit. In `code` mode it skips heading detection and treats the whole thing as one block to greedy-pack.

**Where it wins.** Generic prose without strong heading discipline. README files. The output of an LLM. Source code or log files in `code` mode. When your corpus is mixed — some docs have headings, others don't — `sentence_aware` falls back gracefully where `hierarchy` would emit one giant chunk per heading-free doc.

**Where it falls over.** Anywhere `hierarchy` works. If your markdown has reliable headings, `sentence_aware` is leaving recall on the table by ignoring them. The factorial bakeoff on a 772-doc legal QA corpus put `sentence_aware` in third place behind `hierarchy` and `neighbor_expand` — and the gap was non-trivial.

**My take.** This is the safe default for "I don't know what shape my corpus is and I want predictable behavior." It almost never wins a bakeoff, and it almost never embarrasses itself. Use it as the baseline; replace it when the bakeoff tells you to.

## 2. `hierarchy` — prepend the heading, win every column

**What it does.** Splits on markdown headings (`^#{1,6} `). For each section: `original_content` is the section body, `embedded_content` is `"{heading}\n\n{body}"`. The heading is prepended at embed time so the vector carries the framing context for free.

**Where it wins.** Markdown corpora with meaningful headings. The factorial benchmark — 772 legal docs, 30 gold queries, every embedder column — put `hierarchy` in first place. Every. Column. The reason isn't subtle: the heading acts as embed-time framing, so semantically-adjacent queries pull the right section without the user having to verbatim-match the body. "What does the policy say about X" pulls the X section even if the body never uses the word X — because the heading does.

**Where it falls over.** Two ways. First, your corpus has no headings — `hierarchy` emits one chunk per doc, which is sometimes fine and sometimes catastrophic. Second, your corpus has *aggressive* heading discipline with one-line sections — every footnote becomes its own chunk, retrieval gets noisy. Tune `min_section_chars` up, or switch chunkers.

There is also a corpus shape where `hierarchy` reliably underperforms: short narrative documents with no internal structure. Sales-call notes. Customer support tickets. Slack messages. The note is one paragraph. `hierarchy` collapses the whole thing into one chunk per doc, you lose the ability to differentiate sub-topics within a note, and `fixed_overlap` blows it out of the water on those corpora.

**My take.** This is the production default for marketing pages, technical documentation, internal handbooks, anything that came out of Notion or Confluence with discipline. If your authors use headings the way they're meant to be used, `hierarchy` is hard to beat. If they don't, you're fighting your tool.

## 3. `fixed_overlap` — dumb, predictable, surprisingly hard to beat

**What it does.** Splits the document on whitespace into words, then slides a fixed window. `window_words: 300, step_words: 150` gives 300-word chunks with 150-word overlap. That's it. No heading detection, no paragraph respect, no fancy boundary detection. The simplest chunker in the box.

**Where it wins.** Two completely different corpus shapes, for opposite reasons.

The first is short discrete items — QA pairs, FAQ rows, tweets, support tickets. Each item is short enough that one window covers most of it; the overlap catches the spillover. Predictability is a feature: every chunk is the same size, so embedding behavior is uniform across the corpus.

The second is — and this still surprises me — well-structured technical documentation. On the bakeoff I ran against 31 Postgres docs, `fixed_overlap` won at MRR 0.95. That's higher than `hierarchy` on the same corpus. The hand-wavy theory is that `fixed_overlap` produces multiple focused fragments per doc, and recall@1 benefits from having more "small targets" to hit. The overlap absorbs the boundary noise that pure non-overlapping splits would create.

**Where it falls over.** Long-form prose with strong topical structure. Wikipedia paragraphs. Encyclopedia entries. `fixed_overlap` slices straight through the topic shifts that `hierarchy` and `semantic` would respect, producing chunks that contain the tail of one topic and the head of another. Retrieval gets dilution.

It is also a vector-count amplifier. A 10,000-word doc at 300/150 produces 65 chunks; the same doc at 800-word `hierarchy` chunks produces twelve. For embedding cost, storage cost, and query latency, this matters. On a small corpus you'll never notice. On a 100K-document corpus, it's the difference between a $200 ingest and a $2,000 ingest.

**My take.** Always include `fixed_overlap` in your bakeoff matrix as the baseline. If a more clever chunker can't beat the dumb one, the more clever chunker isn't actually doing anything useful for your data. I have been humbled by `fixed_overlap` more times than I'd like to admit.

## 4. `neighbor_expand` — same chunks, more context at embed time

**What it does.** Wraps any base chunker. Runs the base chunker first; for each base chunk `i` it builds a new vector from the concatenation of chunks `[i-window, i+window]`. Critically: `original_content` stays as chunk `i`'s own body — only the *vector* sees the neighbor context. So when you retrieve chunk 3, you get chunk 3's clean text, but the embedding that pulled it was computed from chunks 2, 3, and 4 glued together.

**Where it wins.** Corpora where the answer to a query spans chunks. Long technical documents where context flows across paragraph breaks. Code documentation where the explanation is in one paragraph and the example is in the next. The factorial bakeoff put `neighbor_expand` (wrapping `sentence_aware`, window=1) in second place behind `hierarchy` — close enough that on certain corpora it flips ahead.

The clean separation between `original_content` and `embedded_content` is genuinely clever. Your audit trail shows clean chunks; your retrieval gets context-aware vectors. You don't pay for the context with a polluted return text.

**Where it falls over.** When you stack it on top of `hierarchy` with `prefix_heading: true`, you're double-dipping on framing context — the heading is already prepended, the neighbor expansion adds *more* context, and the vector starts to drift from what the user is actually querying for. Stick `neighbor_expand` over `sentence_aware` or `fixed_overlap`, not over `hierarchy`.

It also has a `max_chars` failure mode that bites people on long-context embedders. Default base `max_chars: 2000` plus `window: 1` produces ~6000-char concatenations — fine for nomic at 8K context, dangerous for BGE at 512 tokens. Drop the base `max_chars` to ~1500 if you see truncation warnings.

**My take.** This is the chunker I reach for when bakeoff results show recall ceiling — high MRR but lots of "right answer was actually chunk N+1" misses. The fix is rarely a different base chunker; it's giving the existing chunker more context at embed time.

## 5. `semantic` — split where the meaning drifts

**What it does.** No headings? No reliable paragraphs? Walk the document sentence by sentence, embed each sentence with a small dedicated model, compute cosine similarity between consecutive sentences, and cut wherever the similarity drops below the 95th-percentile drop threshold. The output is chunks that respect topic boundaries even when no syntactic cue marked them.

**Where it wins.** Transcripts. Interviews. Auto-captioned audio. Long auto-generated summaries. Mixed-topic FAQ pages where one URL conflates unrelated questions. Anywhere your source has no markdown structure to lean on. Run `hierarchy` over a YouTube transcript and you'll get one giant chunk; run `semantic` and you'll get clean topic-shift breaks.

**Where it falls over.** Three places. First, structured markdown — the dedicated boundary model spends compute computing what the headings already told you for free. `hierarchy` is faster and equally good. Second, code files — semantic drift tracks natural-language topicality, not function boundaries. Use `sentence_aware` with `doc_type: code` instead. Third, very short docs (< 10 sentences) — the similarity stats are too noisy for the percentile cut to mean anything.

There's also a non-trivial speed cost. The default boundary model (MiniLM-L6-v2 int8, ~22 MB) costs roughly 1.2× a main-cell BGE-base embed pass on the same document. You can flip `boundary_model: "same"` to reuse the cell's main embedder, which trades speed (the main model is usually larger and slower) for memory (no second model load).

**My take.** This is the chunker for the corpus shape nobody talks about: stuff humans say. Meeting transcripts. Podcast episodes. Customer support call recordings. The data engineering literature is biased toward documents because documents are easy to fixture. Real production corpora include a lot of speech, and `semantic` is the only chunker in the box that does the right thing on speech.

## 6. `summary_embed` — embed the summary, return the raw

**What it does.** Wraps any base chunker. The base chunker emits chunks normally. Then the summary layer replaces each chunk's `embedded_content` with a summary — generated by an external source column, a callable Python module, or passthrough (the chunk text is the summary). `original_content` stays raw.

**Where it wins.** Long chunks where the vector's signal is diluted by filler. A 1,500-word section where the actual meaning is in two sentences and the rest is procedural prose. Summarize at embed time; you keep the raw text for return, but the vector represents what the chunk is *about*, not every adjective it happens to contain.

The callable mode is where this gets interesting. You can wire chunkshop's `summarizers.lede` (a sibling library that ships fast extractive summarization) so every chunk gets a 2-3 sentence lede summary at ingest time. Or you can wire any Python callable that takes text and returns text — your own LLM-based summarizer, a fine-tuned T5, whatever.

**Where it falls over.** Any corpus where the chunks are already short and dense. Sales notes. Support tickets. Single-paragraph FAQ entries. The summary will either equal the raw text (waste of compute) or worse, drop genuinely-useful detail. Don't summarize what's already a summary.

The external-source-column variant has an underrated use case: your CRM already stores a `subject_line` per row, your CMS already stores an `abstract` per page. Wire those columns as the embed source, no callable needed. You're getting human-authored summaries for free.

**My take.** This is one of the two most powerful chunkers in chunkshop, and it's also the most under-used because it requires you to think about *what gets embedded* as a separate question from *what gets stored*. Most pipelines collapse those into one decision. Once you separate them, a lot of recall headroom shows up.

## 7. `hierarchical_summary` — match coarse, return fine

**What it does.** Wraps any base chunker. Emits two layers of rows in the same target table, linked by a shared `metadata.group_id`. The base chunker emits "fine" rows with `granularity = "fine"`. The summary layer emits "coarse" rows with `granularity = "coarse"` — one per group, holding a summary of the whole group's content. Both layers go into the same vector table.

**Where it wins.** Two-stage retrieval. Query the coarse layer first to find which group is the right group; query the fine layer within that group for the actual answer. This works because coarse summaries are short and dense (low vector dilution, high recall on topical queries), while fine chunks are precise (low recall but high precision once you've narrowed the group).

The grouping is configurable. `fixed_n` groups every N base chunks. `word_budget` groups until a word target is reached. `section_aware` honors heading boundaries when wrapping `hierarchy`. The group_id is in the metadata; downstream code does the join.

**Where it falls over.** Short corpora where there's no point summarizing. Single-document corpora where everything would end up in one group. Anywhere your retrieval logic isn't ready to do two-stage querying — if you're calling the table once and ranking by `embedding <=> query_vec`, you're getting back a mix of coarse and fine rows ranked together, which is rarely what you want. You have to filter on `granularity` or implement a two-stage call.

**My take.** This is the most novel chunker chunkshop ships. I don't know of another open-source ingest tool that does match-coarse-return-fine retrieval as a first-class feature. It's also the chunker that requires the most query-side work — you have to write the two-stage retrieval logic yourself. The win is real on long-context corpora where naive retrieval drowns in dilution; the cost is integration complexity. Bakeoff tells you whether the win is worth the cost on *your* corpus.

## The decision tree

If I had to write a flowchart — and you should ignore it the second your bakeoff tells you otherwise — it would look like this.

- Markdown with real headings → `hierarchy`. Wrap with `neighbor_expand` if your bakeoff shows recall ceiling.
- Plain prose, mixed structure → `sentence_aware`. Solid baseline.
- Short discrete items (FAQ, tweets, tickets) → `fixed_overlap`. Predictable and surprisingly competitive.
- Transcripts, interviews, captioned audio → `semantic`. The only chunker that handles speech-shaped text right.
- Long chunks where the signal is dilute → wrap any of the above in `summary_embed`. Especially if you can wire a fast extractive summarizer.
- Long-context corpora where coarse-then-fine retrieval makes sense → `hierarchical_summary`. Bring two-stage query logic.

That's the menu. The thing that this tour cannot tell you — that no field guide can tell you — is which one wins on *your* corpus. I've now run chunkshop's bakeoff on five different real-world corpora, and the winning chunker has been different on every single one. The corpus shape decides the leaderboard. The leaderboard decides the chunker. You decide the corpus.

Bakeoff first. Field guide second. The order matters more than the entries on the menu.

Next post: the deeper features. Hierarchical summaries in detail, framers, BYO embedders, schema-flex append mode, the modular-backends roadmap, and the weird stuff — the things you can do with chunkshop that I haven't seen anywhere else.
