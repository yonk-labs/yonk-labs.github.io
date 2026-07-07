---
title: "hector"
date: 2026-07-01
draft: false
tags: ["rust", "agents", "tdd", "spec", "ci", "coding-agents"]
summary: "TDD/spec planner that turns product intent into small, deterministic Bob campaigns — one observable behavior per slice, with the verify command and scope caps frozen up front."
externalUrl: "https://github.com/yonk-labs/hector"
---

**hector** sits between a product decision and a coding agent. It takes "build this" and turns it into a campaign of small, deterministic slices — each with one observable behavior, a frozen verify command, and capped editable paths — so a cheaper builder model can run it safely without re-litigating scope mid-task.

## Lifecycle role

Hector doesn't write production code. A frontier orchestrator owns product judgment; hector converts that judgment into an executable contract; [bob](https://github.com/yonk-labs/bob) implements each slice inside its own worktree; [abe](https://github.com/yonk-labs/abe) or a human reviews anything uncertain. The point is to make the implementation task boring enough that a smaller, cheaper model can run it without drifting.

Each slice hector plans defines:

- one observable behavior
- the deterministic command that verifies it
- test/spec files kept as reference-only, not editable
- bob's editable paths and scope caps, frozen before the build starts
- a review step that compares bob's result against the original contract

## What it's for

- **Converting a request into a Bob-sized campaign** — `hector plan` emits campaign YAML bob can run directly, or a `needs_input` response when the request doesn't have enough proof or scope defined yet.
- **Rejecting weak campaigns before they cost a build cycle** — `hector check` statically flags dangerous or underspecified campaigns.
- **Reviewing the result** — `hector review` compares bob's output JSON against the original contract and returns one of `accept`, `accept_for_human_review`, `revise_campaign`, `split_task`, or `ask_human`.
- **Handing frontier models an exact contract** — `hector frontier-brief` (and a `--compact` low-token variant) prints the handoff prompt an orchestrator model needs to request a campaign correctly.

## Quick start

```sh
cargo install --path .
hector init
hector frontier-brief
hector plan \
  --task "Add a focused Bob slice" \
  --verify "cargo test focused_slice" \
  --editable-path src/lib.rs \
  --reference-path tests/focused_slice.rs \
  --out campaign.yaml
hector check --file campaign.yaml
bob campaign --file campaign.yaml
hector review --campaign campaign.yaml --bob-result result.json
```

`hector mcp` exposes the same four operations — `frontier_brief`, `plan_campaign`, `check_campaign`, `review_result` — as a stdio MCP server, so a host agent can call them directly instead of shelling out.

## Links

- [GitHub Repository](https://github.com/yonk-labs/hector)
- Related: [bob](https://github.com/yonk-labs/bob) (the builder that runs hector's campaigns)
- Related: [abe](https://github.com/yonk-labs/abe) (the judge for uncertain results)
- License: Apache 2.0
