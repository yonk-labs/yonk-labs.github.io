---
title: "bob"
date: 2026-07-01
draft: false
tags: ["rust", "agents", "ci", "worktree", "verification", "coding-agents"]
summary: "Autonomous build → verify → judge loop. Bob drives a coding CLI in an isolated git worktree, gates the result on your own test command, and only applies the change once it converges."
externalUrl: "https://github.com/yonk-labs/bob"
---

**bob** takes a task and a repo, drives a builder CLI (`goose` by default, `opencode` for the heavier tier) to make the change in an isolated git worktree, and won't touch your real tree until the change passes your own verify command. Your working directory stays clean during every iteration — nothing lands until the loop converges.

## Why bob?

- **The loop is the value, not the build step.** A single coding-agent run gives you an unverified diff. Bob wraps that in an isolated worktree, an objective gate (your tests have to go green), bounded retries with stuck detection, and an apply gate that defaults to propose-only.
- **Your tests are the authority.** `abe` can weigh in as a second opinion (advisory, blocking, or retry-on-fail), but the verify command you configure is what decides pass or fail — not a model's judgment call.
- **Learns which model to trust.** Bob tracks success rate and latency per model and re-ranks its builder roster every run, so a flaky model sinks and a fast, reliable one floats to the front — without you hand-tuning a config.
- **Built for delegation.** As an MCP server or a Claude Code plugin, a host agent can hand off a bounded unit of work and get back a structured result instead of babysitting a build loop in its own context.

## What it's for

- **Auto-fixing failing tests** — point bob at a red test suite and a verify command; it iterates until the suite is green, then applies.
- **Spec-to-verified-code** — feed it a spec file and the files it should touch; it won't stop until your gate passes.
- **Offloading builds from a host agent** — Claude Code, Codex, or opencode can call bob's `build` MCP tool to get a verified diff back without spending their own context on the iteration loop.
- **Multi-slice campaigns** — chained with [hector](https://github.com/yonk-labs/hector), each campaign slice becomes the next slice's git base, so a whole feature can land as a sequence of small, independently-verified commits.

## How it fits with Hector and Abe

Bob is the *builder* in a three-part loop: **Hector** turns a request into small, verifiable slices with a test/spec already defined; **bob** implements each slice in its own worktree and gates on the verify command; **Abe** reviews or blocks depending on the configured judge policy. None of the three requires the others — bob works standalone with just a task and a verify command — but chained together they form campaign → build → review without a human in the loop for the boring parts.

## Safety model

Worktree isolation, propose-by-default (no `--apply`, no changes to your tree), secret scanning on both the task input and the candidate diff, and scope caps that stop a runaway diff before it applies.

## Links

- [GitHub Repository](https://github.com/yonk-labs/bob)
- Related: [hector](https://github.com/yonk-labs/hector) (the TDD/spec planner that feeds bob campaigns)
- Related: [abe](https://github.com/yonk-labs/abe) (the multi-model judge)
- License: Apache 2.0
