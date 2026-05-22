---
title: "Stele: The Memory Layer I Couldn't Stop Building"
date: 2026-05-21
draft: false
tags: ["stele", "agent-memory", "postgres", "mcp", "ai", "agents", "open-source"]
summary: "I said the implementation needed another quarter. Three weeks later I'd shipped Stele — source-backed, time-traveling, sovereign agent memory that plugs into seven coding assistants. What it does, the three goals driving it, what's solid on main, and what's still wobbly. The honest version, including the parts that aren't built yet."
build:
  list: never
---

A few weeks ago I wrote a post called ["Your Agent Forgets Things"](https://yonk.dev/blog/pg-raggraph-as-agent-memory/). The argument was simple. Coding agents have amnesia. Vector search alone can't fix it because the missing piece is *relational* — "today's bug looks like last Tuesday's bug through three shared developers and a service." That's a graph problem, not a similarity problem.

I made the case that pg-raggraph — the GraphRAG-on-Postgres project I'd been working on — was secretly the right shape for that workload. Time-aware. Retraction-safe. Graph traversal built in. And I ended that post with what I thought was a polite, honest disclaimer: *the architecture fits, the implementation needs another quarter of work.*

Yeah, well. I didn't wait a quarter.

I've been building.

## What I started building

The thing I've been building is called **Stele**.

The name's deliberate. A stele is one of those carved stone monuments — the ancient world used them as durable, source-backed records. You wrote things on them not because you wanted them pretty but because you wanted them to *survive* and you wanted future people to know exactly where the claim came from. That's the shape of what I want for agent memory. Durable. Source-backed. Survives the model that wrote it.

Here's the short version of what Stele does:

- **Stores artifacts exactly.** When an agent runs a tool and the output is huge, Stele swaps it for a `stele://` reference and a scrubbed summary. The exact bytes stay on disk. The model gets a short pointer it can fetch from later. Token bills drop. No information is destroyed.
- **Remembers facts with citations.** Every memory record cites the `stele://` source it came from. Not "the agent thinks Postgres 17 is in use" but "the agent thinks Postgres 17 is in use *because of this artifact, stored at this exact moment, here are the bytes if you want to verify.*"
- **Treats memory like a ledger, not a database.** Facts change. So when Postgres 15 becomes Postgres 17 in your environment, you don't *edit* the old memory — you `add(supersedes=[old_id])`. The old one stays. The new one replaces it on default reads. You can `as_of=last_tuesday` and see what the agent thought last Tuesday. The history is the artifact.
- **Plugs into your AI coding assistant.** Claude Code, Codex, Cursor, OpenCode, Gemini CLI, Copilot, Aider. One `stele install --platform claude-code` and a slash-skill plus an MCP server land in the right place. The agent suddenly has 18 new tools — store, fetch, memory_add, memory_search, recall, the whole surface.

That's it. That's the project. Boring on paper. The interesting part is what falls out of the design.

## The goals I'm actually chasing

Let me be honest about what I want, because I keep telling myself this matters even when I'm three commits deep at 1am.

**One.** I want agents to stop bullshitting me. Every coding agent I use right now will confidently tell me a fact about my codebase that was true two weeks ago and isn't anymore. Sometimes they make stuff up entirely. I don't want a smarter model — that's not the lever. I want a memory layer where every claim the agent makes is *traceable to a specific artifact at a specific point in time*, and where I can rewind to last week and see what the agent thought last week. Evidence. Provenance. Time-travel.

**Two.** I want memory that *evolves* without losing the audit trail. The world changes. Yesterday's `psql 15` is today's `psql 17`. The agent has to be able to say "I learned this on Tuesday, the world updated me on Friday, here's the chain." That means supersession (newer replaces older but old stays queryable), retraction (with a reason, also kept), and time-travel queries. Not metaphorically. Actual SQL, actual `as_of=<datetime>`, actual rows.

**Three.** I want this to be *sovereign*. Not "fine-tuned LLM as a service" sovereign. Real sovereign. Your data, your machine, your stack. SQLite on a laptop, Postgres on a server, whatever. The default is offline. No required calls to anyone's cloud. The MCP server runs locally over stdio. The signing keys are yours. The encryption is yours. If the company that ships Stele tomorrow vanishes, the data is still on your disk, in a documented format, with a one-line JSONL export. (Yes, that's already shipped. I tested it.)

These three goals aren't separable. The reason memory has to be source-backed is that an agent that can't cite where it learned a thing is an agent you can't audit. The reason memory has to evolve is that one-shot facts are wrong in three weeks. The reason it has to be sovereign is that *the second your memory layer is somebody else's product, every interaction is leaking your context to a place you don't control.* I'm done with that.

## What I hope it evolves into

Here's where I'm willing to dream a little.

I want Stele to be the *boring infrastructure* that every long-running agent grows. Not a feature anybody markets. Not a thing you read a blog post about (he says, writing the blog post). The kind of thing you forget is there because it just works. The way you forget there's a filesystem.

A working session in 18 months should look like this. You open Claude Code. The agent gets your project history, your preferences, your last week's decisions, your supersession chain, all from the local Stele instance. None of it leaves your machine. The agent can answer "what database version did we standardize on" without bullshitting because it pulls the answer through `stele_recall(query=, as_of=now)` and cites the `stele://` ref that contains the original decision document. You change databases? `memory_add(supersedes=[old_id])`. The agent on a different machine, a different IDE, a different vendor — none of it matters, because the memory is portable JSONL and the contract is one Python class.

I also want Stele to be *invisible enough that the agent doesn't have to be smart about using it.* The hook that fires on a big Bash output telling the agent "hey, route this through `stash_tool_result`" is doing 80% of the work already. The next version of the hook layer should be even sneakier — the agent shouldn't have to know it's using Stele any more than it knows it's using a filesystem. That's a UX bet. We'll see.

The big bet, though, the one I haven't written about much: **multi-agent shared memory.** Picture three agents working on the same project. One's reading code, one's writing tests, one's filing PRs. They all share a Stele instance. The reader agent stores artifacts. The writer agent extracts memories from those artifacts. The PR agent pulls the relevant context through `recall` and writes a commit message that *cites the artifact that triggered the change.* All on the same stack, no sync layer, just one source of truth. (I'm not there. The single-agent surface had to land first. But the contract is shaped for it.)

## What I've shipped, and what's still wobbly

Look, the honest part of the post.

Five phases are on `main` and they actually work. Phase 1 — memory supersession + `as_of` time-travel. Phase 2 — deterministic extraction (no LLM, just pattern recognition). Phase 3 — recall with seven strategies (`memory_search`, `artifact_search`, `adaptive`, `raw_fetch`, `graph_search`, the lot). Phase 4 — vector and hybrid retrieval across five storage backends through Chunkshop. Phase 5 — living-knowledge graph projection on pg-raggraph, every hit recovering its exact `stele://` source.

699 tests pass on the current branch. Lint and types are clean. I have an end-to-end docker harness that boots Postgres, MariaDB, ClickHouse, and pg-raggraph, runs the full contract suite, and reports green or red. That's the substrate.

This week I added the agent-side packaging: the MCP server, the CLI, install hooks for seven coding assistants. A single Jinja template renders the slash-skill, the hook, and the `mcp.json` entry for whichever platform you pick. I caught a bug in the install path that would have clobbered other tools' `mcp.json` entries — that's fixed and there are 12 tests for it. I caught another bug where `extract_from_artifact` ignored non-default namespaces — that's fixed too. The smoke checklist runs in 15 seconds and proves all seven platforms install, merge correctly, and uninstall clean.

Now the parts that are still rough.

**Forgetting policies are not implemented.** Stele will remember everything you ever told it forever. That's correct for a ledger and wrong for a working memory. I haven't decided on the decay model. "Down-weight unread facts after six months" is the obvious one but I don't trust it without a benchmark.

**Memory consolidation is a stub.** After a thousand sessions you'll have a thousand small memory records about your project. There's no automatic summarization or merging layer. I know what the design should be. Haven't built it.

**Embeddings are opt-in and the default is dumb.** Stele works without any embedding model — it does keyword retrieval, which is faster and cheaper than people give it credit for. If you want vector recall you set `indexing.mode: sync` and Chunkshop picks an embedding model. The defaults are not tuned. The benchmarks for "which embedding model gives the best agent-memory recall" are something I want to publish and haven't.

**Scale is unproven past my laptop and the Docker harness.** The contract tests pass against real Postgres and real ClickHouse. They do not pass against 500,000 memory records across a year of agent use. Anyone who tells you they've benchmarked agent memory at production scale is selling you something. I'm not. I'll publish numbers when I have numbers.

**The MCP tool surface is large.** Eighteen tools. That's not a brag — it's a concern. Agents have to know when to use which one. The skill content tries to help, but I'm watching for whether the agent picks the right tool at the right time. Early signal: it does, mostly. The hook that nudges toward `stash_tool_result` for large outputs is doing a lot of the work.

**This is still new.** I want to be very clear about this. Stele is two months of focused work. It is solid where it's tested and the tests are real. It is not the kind of mature you'd want before betting a production system on it. If you're a tinkerer, an early adopter, a person who likes being on the boundary — I'd love to have you try it and tell me what breaks. If you need stable infrastructure for a paying customer's workload, give me a quarter.

## Early feedback (mostly from me, who is biased)

I've been dogfooding Stele on the Stele repo. (The recursion isn't lost on me. It's also the right test.) Three things stand out.

The slash-skill installation is what I'm most surprised by. I expected the install to be the painful part — every platform has a different skill location, manifest shape, hook mechanism. A single `PLATFORM_CONFIG` dict and one Jinja template handles all seven. Adding the eighth platform is going to be one PR with one dict entry. I borrowed that pattern from how graphify (the OSS project doing static knowledge graphs for AI coding assistants) handles its install — credit where credit is due. I avoided their pitfall of duplicating skill content across fourteen files. One template, N renderings.

The interception layer is paying for itself. When a Bash command spits out 8000 tokens of git log, the agent now calls `stele_stash_tool_result`, gets back a `stele://` ref plus a one-paragraph summary, and keeps working. The next prompt is short because it has a pointer, not a payload. I've watched it cut a 30,000-token context to 4,000 on a normal session. That's not a benchmark, that's a vibes-check. I'll publish numbers when I have a defensible methodology.

The evidence trail is the unsung hero. I'm three weeks deep in dogfooding and I have not yet had Stele tell me a confidently wrong fact. Not because the agent is smarter — it's because every claim is cited and the citation is a `stele://` ref I can `fetch` and read. If the agent ever does hallucinate, the citation will be wrong or missing, and that's a signal I can spot. (Compare this to the standard chatbot answer: "Yes, I remember you said X." Did you, though. Did I.)

## What you can do with it today

There's a [5-minute quickstart](https://github.com/yonk-labs/stele/blob/main/docs/quickstart.md) on the repo. The full path is `pip install stele-core`, `stele init`, `stele install --platform claude-code`, restart Claude Code, type `/stele`. The MCP server is up, the skill is registered, the hook fires on big outputs. If you want to skip the agent and just see what the tool surface does, there's an `examples/mcp_tour.py` that exercises every one of the 18 tools and prints the response.

I want bug reports. I want use cases I haven't thought of. I want to know when the install fails on a setup I haven't tested. I want to know when the agent picks the wrong tool. The repo is open. The license is Apache 2.0. Come break it.

The longer version of all this is the [pg-raggraph-as-agent-memory post](https://yonk.dev/blog/pg-raggraph-as-agent-memory/). That's where the *why* lives. This post is the *what I did about it.* The next post in this series is the *how — the tutorial.* If you want to skip ahead and just try it, the README's quickstart is the fast path.

A last thing. The pg-raggraph post ended with me promising the implementation needed another quarter of work. I'm three weeks in and I have an agent-side surface, full memory semantics, source-backed retrieval, and an install path for seven platforms. The quarter estimate was wrong. (In my defense, I didn't expect to get this fired up.) The honest update is: the architecture *still* needs another quarter. The first quarter delivered a working agent loop. The next one is forgetting policies, consolidation, embedding defaults, scale benchmarks, and the multi-agent story.

If any of that sounds like the right shape, come help me figure out what I'm wrong about.
