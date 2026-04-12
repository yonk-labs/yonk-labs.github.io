---
title: "RoboMonkey MCP (yonk-robo-codemonkey)"
date: 2026-04-12
draft: false
tags: ["python", "mcp", "postgres", "pgvector", "coding-agents", "rag"]
summary: "Local-first MCP server that indexes code and docs into Postgres + pgvector for hybrid retrieval by LLM coding clients."
externalUrl: "https://github.com/TheYonk/yonk-robo-codemonkey"
---

**RoboMonkey MCP** is a local-first [Model Context Protocol](https://modelcontextprotocol.io/) server that indexes code and documentation into PostgreSQL with pgvector, then provides hybrid retrieval — **vector search + full-text search + tags** — to any MCP-compatible coding client (Claude Desktop, Claude Code, etc.).

## Origin Story

> "100% unapologetically vibe coded with the assistance of Claude. The idea came from working on a series of video games over winter break and running into problems with coding agents losing info about files and not understanding the relationships between files."

That's the honest README. RoboMonkey exists because coding agents need persistent, structured memory of your codebase — not a fresh grep on every turn.

## What It Does

- **Indexes your codebase** — analyzes code structure, symbols, and relationships
- **Hybrid retrieval** — combines dense vector embeddings, BM25 full-text search, and tag filtering
- **Background daemon** — watches files, processes changes incrementally, keeps the index fresh
- **MCP integration** — exposes tools to Claude Desktop via a generated `.mcp.json`
- **Pluggable embeddings** — Ollama, vLLM, or OpenAI

## Tech Stack

- **Language:** Python 3.11+
- **Storage:** PostgreSQL with pgvector
- **Runtime:** Docker Compose for Postgres, background Python daemon for watching/indexing
- **Embeddings:** Ollama / vLLM / OpenAI
- **Interface:** MCP server

## Quick Start

```bash
./quick_start.sh
```

The script creates a venv, starts Postgres+pgvector in Docker, configures your embedding and LLM providers interactively, indexes a repo of your choice, starts the daemon, and writes `.mcp.json` for Claude Desktop. Takedown is a single `./quick_teardown.sh`.

## Links

- [GitHub Repository](https://github.com/TheYonk/yonk-robo-codemonkey)
- License: Apache 2.0
