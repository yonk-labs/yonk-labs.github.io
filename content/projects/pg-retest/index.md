---
title: "pg-retest"
date: 2026-03-20
draft: false
tags: ["rust", "postgresql", "workload-replay", "benchmarking", "migration-testing"]
summary: "Capture, replay, and compare PostgreSQL workloads. Validate config changes, migrations, and capacity plans with confidence."
externalUrl: "https://github.com/pg-retest/pg-retest"
---

**pg-retest** captures production PostgreSQL traffic and replays it against test targets so you can validate configuration changes, version upgrades, server migrations, and capacity plans before they hit production. Think of it as Oracle RAT for PostgreSQL — with modern tooling and a demo environment you can spin up in one command.

## Why pg-retest?

- **Pre-migration validation** — Replay production traffic against your new datacenter, hardware, or cloud target before cutting over.
- **Version & patch testing** — Upgrading PostgreSQL 15 → 16? Replay your exact workload and catch regressions before they ship.
- **Configuration benchmarking** — Changed `shared_buffers` or `work_mem`? Compare before and after with real queries, not synthetic benchmarks.
- **Cloud provider evaluation** — RDS vs. Aurora vs. AlloyDB vs. self-hosted — replay identical traffic against each.
- **Capacity planning** — Scale workloads 2x, 5x, 10x to find where things break before Black Friday does.
- **CI/CD regression gates** — Automated pass/fail on every schema migration or config change.
- **Cross-database migration** — Moving from MySQL to PostgreSQL? Capture, transform SQL, and validate on PG.
- **AI-assisted optimization** — LLM-powered tuning recommendations, validated against your real workload with automatic rollback on regression.

## Accuracy

pg-retest is a workload *simulation* tool, not a replication system. Replay produces a high-fidelity approximation of production traffic: **93-96% accuracy for write workloads** with `--id-mode=full`, **near-100% for read-only**. The 4-7% error on writes comes from concurrent session sequence ordering — the same fundamental limitation Oracle RAT documents as "replay divergence."

Use pg-retest to answer *"will my workload perform the same on the new target?"* — not *"will my data be byte-identical?"*

## Tech Stack

- **Language:** Rust
- **Target:** PostgreSQL 12+
- **Quality bar:** 323 tests, zero clippy warnings

## Quick Start

```bash
git clone https://github.com/pg-retest/pg-retest.git
cd pg-retest
docker compose up --build
# Open http://localhost:8080 and click "Demo"
```

The demo ships two PostgreSQL 16 instances seeded with a 94k-row e-commerce dataset and a pre-built workload (357 queries, 8 concurrent sessions). The Demo page walks you through inspect → replay → compare → scale → AI tuning.

## Links

- [GitHub Repository](https://github.com/pg-retest/pg-retest)
- License: Apache 2.0
