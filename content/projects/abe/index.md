---
title: "abe"
date: 2026-07-01
draft: false
tags: ["rust", "agents", "llm", "debate", "code-review", "mcp"]
summary: "Multi-model LLM debate and second-opinion validation. Broadcasts a prompt to several models — HTTP providers or local CLIs — has them argue over N rounds, and returns a synthesized answer plus an agreement/disagreement report."
externalUrl: "https://github.com/yonk-labs/abe"
---

**abe** (named for Lincoln, one of history's great debaters) puts more than one model on a question instead of trusting a single answer. It broadcasts a prompt to several LLMs, runs them through a configurable number of critique rounds, and returns a synthesized final answer along with a report on where the models agreed and where they didn't.

## Why abe?

- **A second opinion, automatically.** A second model reads the first's answer and disagrees where it would — catching the confident-but-wrong case a single pass misses.
- **Works with zero cloud config.** Models can be HTTP providers (OpenAI, Anthropic, any OpenAI-compatible endpoint) or local CLIs (`codex`, `claude`, `opencode`), mixed freely in the same debate. Pair two CLI providers and there's no API key to manage at all.
- **Grounded in your material.** Attach a design doc, a README, a PR diff — the debate argues over your actual document, not a generic prompt.
- **Personas give the panel real disagreement.** Assign one model a security lens and another an SRE lens instead of two models politely agreeing with each other.
- **Three surfaces.** A CLI, a stdio MCP server for Claude Code / Codex / opencode, and a small web UI with a JSON API.

## What it's for

- **Second-guessing a decision** — `abe validate` runs one reviewer against a statement you're about to act on.
- **Full debate on a design question** — `abe debate` runs a multi-round argument across every configured model and returns a synthesized verdict.
- **In-editor validation from an agent** — as an MCP server, Claude Code or opencode can call `debate`/`validate` directly mid-session instead of you copy-pasting prompts elsewhere.
- **Reviewing a diff or spec with distinct lenses** — attach the file, assign personas per model, and get a panel argument instead of one model's take.

## How it works

Abe broadcasts the prompt to every configured model concurrently, then for each critique round shows each model the others' latest (anonymized) answers and asks it to revise. A decision protocol — `synthesis` (a chairman model merges everything), `judge` (a judge model scores and picks one verbatim), or `majority` (deterministic clustering, no extra model call) — produces the final answer. Raw per-model answers are always preserved in the result.

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/yonk-labs/abe/main/install.sh | sh
abe init                                             # interactive model setup
abe debate "Is Postgres a good default database?"
abe validate --reviewer codex "We should rewrite this service in Rust."
```

## Links

- [GitHub Repository](https://github.com/yonk-labs/abe)
- Related: [bob](https://github.com/yonk-labs/bob) (uses abe as its judge)
- Related: [lede](https://github.com/yonk-labs/lede) (abe's `--lede` flag compresses oversized `--files` context without an extra LLM call)
- License: MIT
