---
title: "pg-wire-core"
date: 2026-07-01
draft: false
tags: ["rust", "postgresql", "wire-protocol", "proxy", "networking"]
summary: "PostgreSQL wire-protocol codec, session pool, and socket helpers as a reusable Rust crate — the foundation layer extracted from pg-retest's proxy for building a Postgres router."
externalUrl: "https://github.com/yonk-labs/pg-wire-core"
---

**pg-wire-core** is a foundation crate: the PostgreSQL wire-protocol codec, a session connection pool, and socket-hardening helpers, pulled out of [pg-retest](https://github.com/pg-retest/pg-retest)'s proxy layer and packaged as a standalone Rust library.

## Why it exists

The expensive, easy-to-get-wrong part of any Postgres proxy is the wire protocol itself — startup/SSL/auth, the simple query path, the extended protocol's Parse/Bind/Execute sequence, and pulling routing-key values out of Bind parameters. `pg-retest` already solved that and had it running against real traffic. Rather than rewrite it for a new router project, this crate reuses it verbatim: the four module sources are copied straight from `pg-retest/src/proxy/{protocol,pg_binary,pool,socket}.rs`, with only crate scaffolding added around them.

The intended consumer is a Rust Postgres router — specifically a distributed-cache-ring sharding proxy that routes by key to `pg_memtable` nodes — where Rust's lack of a GC matches the predictable-tail-latency goal the router is built around.

## Modules

- `protocol` — wire read/parse/write: startup, SSL negotiation, auth, Simple Query, the extended protocol, and Bind parameter-value extraction (the source of the routing key).
- `pg_binary` — typed binary/text value decoding.
- `pool` — `SessionPool`, a session-mode TCP pool to one target; instantiate one per shard for a per-node pool registry.
- `socket` — TCP socket hardening and connect-with-timeout.

## Status

v0.1.0. 97 of 97 inherited unit tests pass, zero-warning build. Item visibility (`pub(crate)`/`pub(super)`) carries over unchanged from the source, so some internals aren't part of the public API yet — they widen to `pub` as the router that consumes this crate needs them.

## Build

```bash
cargo build
cargo test    # 97 passing
```

## Links

- [GitHub Repository](https://github.com/yonk-labs/pg-wire-core)
- License: Apache 2.0
