---
title: "Meet chunkshop. Yes, the name is a mistake. No, I'm not changing it."
date: 2026-05-01
draft: false
tags: ["chunkshop", "rag", "postgres", "pgvector", "ingest", "chunking", "embeddings"]
summary: "An illegal chop shop for your data — the YAML-driven RAG ingest tool that ships a bakeoff primitive so you measure chunker × embedder × your corpus instead of vibe-picking from somebody else's blog post."
build:
  list: never
---

Some software gets named in a strategy meeting. There's a whiteboard, a thesaurus, a marketing person, snacks. Someone says "let's call it Convergence" and someone else says "no, that sounds like a Salesforce product" and three weeks later you ship something called Lattice.

That is not how chunkshop got its name.

Chunkshop got its name at 5:47 AM, before coffee, on a morning where I had been awake for about ninety seconds. I'd been thinking about RAG ingest pipelines the night before — chunking strategies, embedding choice, the whole graveyard of decisions that determine whether your retriever returns the right document or the document next to the right document. I sat down, opened a fresh repo, and typed `chunkshop`. Why? Because in my pre-coffee brain it sounded like a chop shop for data — a slightly off-the-books garage where you bring your documents in and they get chunked, tagged, and shipped out to a vector store with the VINs filed off.

I thought it was funny. I committed the name. I went and made coffee.

By the time the caffeine landed I was already three commits in and I could not be bothered to rename anything. So here we are. Chunkshop. An illegal shop for your data. The name is a bit, the bit is permanent, and the tool is real.

## What it actually is

Strip the joke off and chunkshop is one thing: a YAML-driven ingest tool that takes documents from somewhere — files, a Postgres table, S3, a JSON corpus, your application via inline mode — chunks them, optionally pulls structured metadata, embeds with whichever model you point at it, and writes pgvector rows. One YAML file describes one ingest. We call that a "cell." Run it from the CLI, embed it as a library, orchestrate a hundred of them in parallel — same shape every time.

That sounds like fifteen other libraries, and on the surface it is. The thing chunkshop does that the fifteen others don't is treat chunking and embedding as choices you should *measure*, not vibe-pick. Which gets us to the part of this post that isn't a coffee anecdote.

## FOSDEM, February 2026

I gave a talk at FOSDEM this year on the data-engineering layer of RAG. The title was something like "Your AI Is Returning Garbage Because Your Pipeline Is Garbage." I am paraphrasing my own talk because the official title was longer and more polite. The actual content was: chunker choice and embedder choice and quantization choice and chunk size all interact, none of them are obvious in advance, and the entire industry is currently picking these by reading someone else's blog post and going "yeah, that one."

I spent forty minutes on stage being mildly ranty about it. Then in the hallway track I had the same conversation about a dozen times.

> "Cool talk, what chunker should I use?"

That question is the one I cannot answer, and the realization that it is unanswerable in the abstract is the entire reason chunkshop exists in the form it exists. The honest answer is "I don't know, I haven't seen your data." The dishonest-but-popular answer is to pick the one that won on whatever benchmark the questioner happens to remember. Most of the talks at most of the conferences right now ship that dishonest answer, and they don't even know they're doing it.

So in the hallway, after about the seventh round of the same question, I started saying: "I don't know what chunker you should use. But you can find out in fifteen minutes if you have a pgvector instance and ten gold queries." I started drawing on napkins. I drew the matrix. The matrix is just chunkers on one axis, embedders on the other, your corpus in the middle, MRR in the cells. It's not a research method. It's a Tuesday afternoon.

That's the bakeoff. That's what shipped. Cross-product every chunker × every embedder × your data, score with simple recall metrics, hand back a leaderboard plus a runnable winner config. No LLM calls. No API costs. The only thing it spends is some pgvector storage and about fifteen minutes of wall time.

Nobody else was shipping this primitive. Plenty of academic papers run cross-products like this in the methodology section, but they leave it there — between the abstract and the conclusion. The papers don't ship a `bakeoff` subcommand you can run on Wednesday morning. The libraries don't ship one either. They ship recommendations from the corpus the library author had in front of them, and you're supposed to trust that your corpus looks like theirs.

Your corpus does not look like theirs. I've now run chunkshop's bakeoff on three different corpora — Postgres docs, sales call notes, a Wikipedia-style multi-hop QA set — and the winning chunker was different on every single one. Same tool, same matrix, three different leaderboards. The README's recommended default was right exactly once. That is the empirical case for chunkshop's existence.

## What's in the box

Seven chunkers. Six embedders out of the box, plus a four-line YAML pattern for bringing your own ONNX model from any HuggingFace repo. Five metadata extractors (RAKE, KeyBERT, spaCy NER, language detection, and a composite that chains them). A framer stage that re-slices a giant markdown dump into one document per heading before chunking. Schema-flex append mode so multiple cells can write into the same target table with provenance preserved. A bakeoff subcommand that runs the cross-product I just described. An inline mode so you can call `pipeline.ingest_text(doc_id, text)` from a webhook handler instead of running a CLI.

Cross-language vector compatibility is the part I'm a little smug about. The Python implementation is the reference. The Rust port is shipping incrementally. Both implementations write the same `(doc_id, seq_num)` schema, both use the same int8 BGE models, and a vector embedded by Python is byte-compatible with one embedded by Rust. You can run the Python ingest in batch overnight and the Rust ingest from a service mesh, and they share the same target table. Go is on the roadmap. The whole thing is YAML-first specifically so the schema is the contract, not the language.

If that sounds like a lot, it is. Most of it exists because I needed it for some adjacent project — pg-raggraph, the Postgres-native GraphRAG library that pairs with chunkshop and was the original reason I cared about chunker choice in the first place. Each feature has a "yeah I had this exact problem on Tuesday" story attached to it. There is no roadmap-driven development here. There is "Matt yelled at his terminal and committed something."

## Where to go next

I'm running this as a four-part series. This post is the introduction. The next three:

- **Part 2:** A full tutorial on a sales-CRM dataset. We pull notes out of Postgres, run a bakeoff with three baked-in models plus Snowflake Arctic Embed pulled from HuggingFace, do hybrid search on JOINed metadata, pick a winner, then wire it into a LangGraph agent and talk about keeping the index fresh as new notes land.
- **Part 3:** A tour of the seven chunkers — what each one is good at, where each one falls over, the corpus shapes that flip the leaderboard between them.
- **Part 4:** The deeper features. Hierarchical summaries for match-coarse / return-fine retrieval. Framers. BYO embedders. The cross-language vector compatibility story. The modular-backends work-in-progress that points at MariaDB and ClickHouse alongside Postgres. Things you can do with chunkshop that I haven't seen anywhere else.

If you don't want to wait for part 2 to play with it, the [GitHub repo](https://github.com/yonk-labs/chunkshop) has runnable samples for every feature. The `docs/samples/` directory has a `run_demo.sh` per feature; if you've got a Postgres with pgvector reachable, every one of them is one bash command from a populated table.

And yes, the name is permanent. I had three weeks where I considered renaming it. Then I realized "chunkshop" is the kind of name that makes people remember what it does, and a serious name like "VectorForge" or "EmbedKit" would have been forgettable in exactly the way the joke isn't. So we're keeping it. The illegal data chop shop is open for business.

Pull up. We'll chunk it for you.
