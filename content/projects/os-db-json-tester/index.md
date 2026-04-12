---
title: "os-db-json-tester"
date: 2026-04-12
draft: false
tags: ["python", "postgresql", "mysql", "mongodb", "benchmarking", "json"]
summary: "Scripts to test and benchmark JSON functionality across MySQL, PostgreSQL, and MongoDB — and generate simulated load."
externalUrl: "https://github.com/TheYonk/os-db-json-tester"
---

**os-db-json-tester** is a benchmarking and load-generation suite for comparing how MySQL, PostgreSQL, and MongoDB handle JSON workloads. It seeds a movie/actor dataset, runs a configurable website-style workload, and lets you probe query performance and concurrency behavior across all three databases with the same harness.

## Overview

Each database has different strengths when it comes to JSON: PostgreSQL has `jsonb` with GIN indexes, MySQL has JSON columns and generated-column indexes, and MongoDB is document-native. os-db-json-tester gives you a single tool to stress-test them all with a realistic workload (loading actors, titles, movies, and directors; running mixed read/write traffic).

## Tech Stack

- **Language:** Python
- **Targets:** PostgreSQL, MySQL, MongoDB
- **Packaging:** Docker container (PostgreSQL target)

## Quick Start

**Local (macOS):**

```bash
brew install mysql pkg-config
pip install -r requirement.txt
python bench/app_controller.py -f ./bench/app_config/xxx.json
```

**Docker (PostgreSQL):**

```bash
docker build -t os-db-json-tester .
docker run -it --env-file .envfile os-db-json-tester
```

The `.envfile` takes `HOSTNAME`, `USERNAME`, `PASSWORD`, and `DATABASE` — `start_bench.sh` uses these to generate the runtime config.

## Links

- [GitHub Repository](https://github.com/TheYonk/os-db-json-tester)
- License: MIT
