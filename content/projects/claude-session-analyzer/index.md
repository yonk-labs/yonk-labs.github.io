---
title: "claude-session-analyzer"
date: 2026-07-01
draft: false
tags: ["python", "claude-code", "observability", "cli", "tui", "textual"]
summary: "Reads Claude Code's own session transcripts and turns them into tokens, cost, time, and per-skill behavior — which prompt or skill is quietly ballooning your context, and which one keeps asking you questions."
externalUrl: "https://github.com/yonk-labs/claude-session-analyzer"
---

Claude Code already writes a full JSONL transcript of every session to `~/.claude/projects/`. **claude-session-analyzer** (`csa`) reads those transcripts directly — no wrapper, no instrumentation, no extra capture step — and turns them into spend, token bloat, and per-skill behavior you can actually see.

## Why csa?

- **The data already exists; nothing needs to be recorded.** A large `CLAUDE.md`, a stack of skills, and a pile of MCP servers ride along in context on every turn, and most of that cost is invisible until you read the raw transcripts yourself. `csa` does that reading for you.
- **Bloat, not just spend.** The headline number is the ratio of cache-read tokens (standing context replayed every turn) to fresh input tokens — often several hundred to one. Cache-read is cheap per token, but it's still a constant tax on every turn.
- **Per-skill regret.** Each skill gets a turn count, a token cost, and a "regret%" — the share of its turns that show friction (a correction, a walkback, a tool error). Skills that fired fewer than 5 times are marked and sunk in the sort so one bad run doesn't look like a pattern.
- **An honest 3-way time split.** Turn duration breaks into tool execution time, time spent waiting on you (`AskUserQuestion`), and model think time — the gap between an instant tool call and the next action, which is otherwise invisible.

## What it's for

- **Finding the skill that's quietly expensive** — which one loads the most context per run, and whether that cost buys anything.
- **Auditing spend across every project** — a corpus-wide report across every session Claude Code has ever run on the machine, or scoped to just the current directory with `--local`.
- **Debugging a single slow or frustrating session** — drill into one transcript, turn by turn, down to the full tool input and result for any single step.
- **Deciding what to prune** — a big `CLAUDE.md` or a rarely-used MCP server has a token cost every single turn; `csa` is how you see that cost instead of guessing at it.

## Quick start

```bash
pipx install claude-session-analyzer
csa            # corpus profile: spend, bloat ratio, top sessions
csa --tui       # interactive browser: projects → sessions → turns → tool calls
```

The text CLI is stdlib-only; the TUI's one dependency is [Textual](https://textual.textualize.io/).

## What it measures (and what it doesn't)

`csa` measures tax — tokens, cost, time — not answer quality. Friction signals are labeled as correlation, not proof, everywhere they appear in the UI; `tok/s` is end-to-end throughput, not decode speed, since transcripts only carry completion timestamps.

## Links

- [GitHub Repository](https://github.com/yonk-labs/claude-session-analyzer)
- License: Apache 2.0
