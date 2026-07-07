---
title: "ai-skills"
date: 2026-07-01
draft: false
tags: ["claude-code", "skills", "agents", "workflow", "content-generation"]
summary: "A library of opinionated Claude Code skills, rules, agents, and slash commands that turn an AI coding session into an actual workflow — scope before planning, research before content, tests before claims, evidence before opinions."
externalUrl: "https://github.com/yonk-labs/yonk-ai-skills"
---

**ai-skills** is a library built to stop the failure modes that show up once an AI coding session runs long enough: declaring victory on a task it silently redefined, generating content that reads like a vendor pitch, auditing code without ever running it, or shipping a white paper with a fabricated stat. It's 34 skills organized by pipeline stage, 12 behavioral rules that auto-load into every session, 8 reviewer/validator agents, 7 lifecycle slash commands, and 12 pre-built personas so generated content has a real voice instead of a generic one — installed with one script and usable from any project on the machine.

## The pipeline

Skills are organized by stage of work rather than as a flat list: **Understand** (research-base, reverse-engineer, market-intel) → **Scope** (mission-brief, project-compass, whats-next) → **Build** (Claude Code itself, alongside superpowers and spec-kit) → **Audit** (aat, prod-ready, ux-audit, dry-check, anti-vibe, secret-scan) → **Test** (demo-steps, browser-test, user-test, edge-cases, breakme) → **Ship** (prod-ready, security-audit, launch-pad). Content generation (`gen-blog`, `gen-deck`, `gen-podcast`, and friends) runs orthogonal to that lifecycle — it can fire while a feature is still being built or months after launch.

## What's distinct about it

- **Persona-driven content generation.** Twelve pre-built voices (each with ElevenLabs TTS settings), and every content-generation skill runs its output through `/not-an-ai` to strip AI writing tells before it ships.
- **Journey-based testing, not just unit tests.** `/demo-steps` maps real user workflows as YAML; `/browser-test` runs them in Playwright across desktop, tablet, and mobile with click counts and error capture; `/user-test` simulates five different skill levels actually installing and using the thing.
- **Multi-document audits.** `/aat`, `/prod-ready`, `/dry-check`, and `/ux-audit` don't produce a single report — they produce a Gap Analysis, Risk Assessment, Fix Plan, and a task index ready to drop into an issue tracker.
- **Shared research caching.** `/research-base` runs once and every downstream skill consumes it, instead of five separate skills each re-running the same competitive research.
- **The Rethinking, before any rebuild classification.** `/tech-regret` opens with "if I were building this today, knowing everything V1 taught me, what would I do differently?" before it classifies a single component as borrow, rebuild, or discard.

## Install

```bash
git clone https://github.com/yonk-labs/yonk-ai-skills.git ~/yonk-apps/yonk-ai-skills
cd ~/yonk-apps/yonk-ai-skills
./install.sh
```

Installs to `~/.claude/`; rules auto-load in every session after that, in every project on the machine. The installer never overwrites an existing file with different content unless you pass `--overwrite`.

## Complements, not competitors

Built to layer with, not replace: [spec-kit](https://github.com/github/spec-kit) owns the spec-to-code pipeline; [superpowers](https://github.com/obra/superpowers) owns plan execution and TDD discipline; ai-skills owns everything around the code — understanding, scoping, auditing, testing, writing, launching, and rebuilding.

## Links

- [GitHub Repository](https://github.com/yonk-labs/yonk-ai-skills)
- License: MIT
