---
title: "specy"
date: 2026-07-01
draft: false
tags: ["claude-code", "plugin", "spec", "planning", "agents"]
summary: "Guided spec conductor: an assertive interview that turns a fuzzy idea, or a pile of existing code, into one agent-ready SPEC.md — by interrogating why, researching what you don't know, and pulling in other models to attack your reasoning."
externalUrl: "https://github.com/yonk-labs/specy"
---

**specy** is a Claude Code plugin that runs `/spec` — a guided interview that walks from a fuzzy idea, or an existing codebase, to a single authoritative `SPEC.md` a coding agent can build from. It doesn't just ask questions; it conducts a sequence of curated methods (success definition, competitive analysis, prior-art research, constitution, codebase mapping, gap analysis, persona voicing) through one interrogation, then synthesizes the answers into one document.

## How it's built

specy is self-contained — it ships its own slimmed-down versions of each method skill so it works standalone with nothing else installed. It runs amplify-first: if the full versions are installed from the public [ai-skills](https://github.com/yonk-labs/yonk-ai-skills) library, specy prefers those automatically and falls back to its bundled versions otherwise. Heavier standalone tools — `abe` for multi-model debate, `superpowers:writing-plans` for the final plan hand-off — are used if present, but nothing is required.

## The 12 phases

Frame → Why ×5 → Users & Jobs → Success → Compete & Differentiate → Vision & Non-negotiables → Features & Scope → Design (how it works) → Stack → Architecture → Persona Review → Synthesize. Each phase runs a bundled method skill; optional tools like `abe` sharpen a phase further when installed. State lives in `SPEC.md`'s own YAML frontmatter, so the interview can be quit and resumed at any point — the filesystem is the database.

## Usage

```
/spec "a tool that turns ideas into specs"   # idea mode
/spec ./my-project                            # codebase mode — maps current state first
/spec status                                  # what's answered / stubbed
/spec resume                                  # pick up where you left off
/spec jump stack                              # jump straight to a phase
/spec "an idea" --brutal                      # AAT-style critique, plus abe debates if installed
```

Default temperament is assertive — it pushes back on vague answers rather than accepting them. Dial it with `--gentle` or `--brutal`.

## What it's for

- **Turning a fuzzy idea into a build-ready spec** — one document a coding agent can implement directly from, instead of a scattered thread of decisions.
- **Mapping an existing codebase before extending it** — codebase mode runs a reverse-engineering pass first, so the interview starts from what's actually there.
- **Stress-testing a plan before committing to it** — `--brutal` mode brings in adversarial critique and multi-model debate on the weakest points.

## Links

- [GitHub Repository](https://github.com/yonk-labs/specy)
- Related: [yonk-ai-skills](https://github.com/yonk-labs/yonk-ai-skills) (the full-depth method skills specy prefers when installed)
- Related: [abe](https://github.com/yonk-labs/abe) (used for `--brutal` mode debates)
