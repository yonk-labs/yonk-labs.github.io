---
title: "pg-retest in 15 Minutes: From Git Clone to Your First Real Replay"
date: 2026-04-20
draft: false
tags: ["pg-retest", "postgres", "benchmarking", "testing", "getting-started"]
summary: "From git clone to capturing a real PostgreSQL workload and replaying it against a test target — end-to-end on your laptop, with every command actually run."
---


Most database testing tools have a dirty secret. They don't test your database. They test some other database that happens to be installed in the same place yours is. pgbench runs a TPC-B banking workload. HammerDB runs TPROC-C. Sysbench runs whatever sysbench runs. None of it looks anything like the traffic your application actually sends on a Tuesday at 2pm when everything is fine, or on Friday at 4:57pm when everything is on fire.

pg-retest fixes that by letting you capture the queries your real application actually ran, save them to a file, and then replay that file against any PostgreSQL instance you want. New PG version? Replay. New instance type? Replay. Parameter group change? Replay. Different hardware? Replay. Same workload, same concurrency, same timing, measured the same way every time.

This post walks you from git clone to first successful capture/replay/compare against two real PostgreSQL containers on your laptop. Every command below was run on a real machine before it hit this page. If an output block shows you one thing and you see another, I want to know.

## What you'll need

Versions I ran this with:

```
$ docker --version
Docker version 29.1.5, build 0e6fee6

$ rustc --version
rustc 1.93.1 (01f6ddf75 2026-02-11)
```

Docker for the two PostgreSQL containers (source and target). Rust 1.70 or newer for the build. A spare half hour. No cloud account, no API keys, no accounts anywhere. Everything runs on your laptop and leaves no trail when you're done.

If you don't have Rust: `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh` and restart your shell. If you don't have Docker, well, this is 2026, go install Docker.

## Step 1: Clone and build

```bash
git clone https://github.com/pg-retest/pg-retest.git
cd pg-retest
cargo build --release
```

That drops a release binary at `target/release/pg-retest`. The build pulls a fair number of crates the first time (tokio, axum, rustls, tokio-postgres, rusqlite, dashmap, and friends), so expect a few minutes of compile on a cold cache. Subsequent builds are seconds.

A sanity check while you wait:

```
$ ./target/release/pg-retest --version
pg-retest 1.0.0-rc.2
```

If you see that, you're done with the build. The rest of the post uses that binary directly.

## Step 2: Stand up a source PostgreSQL (with the logging config that actually matters)

pg-retest has three ways to capture workload: parse PostgreSQL's CSV logs, sit in front of PG as a transparent wire-protocol proxy, or pull logs directly from AWS RDS/Aurora. We'll use CSV log capture for this post because it has the fewest moving parts and works on any PG you can SSH into.

Here's where I want to save you the two hours I burned the first time I did this. PostgreSQL has two different options that affect statement logging, and they interact in a way that silently produces the wrong format if you get it wrong:

- `log_statement = all` makes PG log every statement on its own line
- `log_min_duration_statement = 0` makes PG log every statement **along with its duration** on a single line

pg-retest's CSV parser needs the *combined* format: `duration: 0.584 ms  statement: SELECT ...`. That means you want `log_min_duration_statement = 0` and `log_statement = none`. If you set both to the verbose options, PG double-logs the statements as separate rows, pg-retest parses zero queries, and you sit there wondering why you're getting empty workload profiles. (Ask me how I know.)

With that out of the way, start your source PG:

```bash
docker run -d --name blog-pg-source -p 15500:5432 \
  -e POSTGRES_PASSWORD=demo -e POSTGRES_USER=demo -e POSTGRES_DB=shop \
  postgres:16 \
  -c log_destination=csvlog \
  -c logging_collector=on \
  -c log_directory=log \
  -c log_filename=postgresql.log \
  -c log_statement=none \
  -c log_min_duration_statement=0
```

The `-c` flags pass PostgreSQL server options without you having to edit `postgresql.conf`. Setting `log_directory=log` (a subdirectory of `/var/lib/postgresql/data/`) keeps the logs in a place the `postgres` user already owns. If you try to bind-mount a host directory for the logs, the postgres user inside the container can't write to it and PG refuses to start. You end up with a container that exits immediately and no log output explaining why. That's Docker permissions for you.

Give it five seconds to warm up and confirm it's ready:

```
$ docker exec blog-pg-source pg_isready -U demo -d shop
/var/run/postgresql:5432 - accepting connections
```

## Step 3: Stand up a target PostgreSQL

The target can be the same version, a different version, a different parameter set, whatever you want to test. For the intro, let's just use the same PG 16 image with default config. Different port so the two containers don't fight:

```bash
docker run -d --name blog-pg-target -p 15501:5432 \
  -e POSTGRES_PASSWORD=demo -e POSTGRES_USER=demo -e POSTGRES_DB=shop \
  postgres:16
```

Give it a moment, confirm it's up:

```
$ docker exec blog-pg-target pg_isready -U demo -d shop
/var/run/postgresql:5432 - accepting connections
```

## Step 4: Seed a schema on both

You want the same schema on both PGs, because you're testing the query engine, not the schema migration. A tiny e-commerce model is enough:

```bash
docker exec blog-pg-source psql -U demo -d shop -c "
CREATE TABLE customers (id SERIAL PRIMARY KEY, email TEXT UNIQUE NOT NULL, created_at TIMESTAMPTZ DEFAULT now());
CREATE TABLE products (id SERIAL PRIMARY KEY, sku TEXT UNIQUE NOT NULL, name TEXT NOT NULL, price_cents INTEGER NOT NULL, stock INTEGER NOT NULL);
CREATE TABLE orders (id SERIAL PRIMARY KEY, customer_id INTEGER REFERENCES customers, total_cents INTEGER NOT NULL, status TEXT NOT NULL DEFAULT 'pending', created_at TIMESTAMPTZ DEFAULT now());
CREATE TABLE order_items (id SERIAL PRIMARY KEY, order_id INTEGER REFERENCES orders, product_id INTEGER REFERENCES products, quantity INTEGER NOT NULL, price_cents INTEGER NOT NULL);
CREATE INDEX idx_orders_customer ON orders(customer_id);
CREATE INDEX idx_orders_status ON orders(status);
CREATE INDEX idx_items_order ON order_items(order_id);
INSERT INTO customers (email) SELECT 'user'||g||'@shop.test' FROM generate_series(1,500) g;
INSERT INTO products (sku, name, price_cents, stock) SELECT 'SKU'||g, 'Product '||g, (100+g*11)%9900+100, 50+g%300 FROM generate_series(1,200) g;
"
```

Copy-paste that exact block into the target too, swapping the container name:

```bash
docker exec blog-pg-target psql -U demo -d shop -c "
CREATE TABLE customers (id SERIAL PRIMARY KEY, email TEXT UNIQUE NOT NULL, created_at TIMESTAMPTZ DEFAULT now());
CREATE TABLE products (id SERIAL PRIMARY KEY, sku TEXT UNIQUE NOT NULL, name TEXT NOT NULL, price_cents INTEGER NOT NULL, stock INTEGER NOT NULL);
CREATE TABLE orders (id SERIAL PRIMARY KEY, customer_id INTEGER REFERENCES customers, total_cents INTEGER NOT NULL, status TEXT NOT NULL DEFAULT 'pending', created_at TIMESTAMPTZ DEFAULT now());
CREATE TABLE order_items (id SERIAL PRIMARY KEY, order_id INTEGER REFERENCES orders, product_id INTEGER REFERENCES products, quantity INTEGER NOT NULL, price_cents INTEGER NOT NULL);
CREATE INDEX idx_orders_customer ON orders(customer_id);
CREATE INDEX idx_orders_status ON orders(status);
CREATE INDEX idx_items_order ON order_items(order_id);
INSERT INTO customers (email) SELECT 'user'||g||'@shop.test' FROM generate_series(1,500) g;
INSERT INTO products (sku, name, price_cents, stock) SELECT 'SKU'||g, 'Product '||g, (100+g*11)%9900+100, 50+g%300 FROM generate_series(1,200) g;
"
```

500 customers and 200 products on each. That's not "real e-commerce," but it's enough to get interesting query plans without waiting all day.

## Step 5: Generate some workload on the source

For a blog post we need workload that feels like an application, not a pgbench run. Real applications read, look something up, then do a write, then read again. Put this in a file:

```bash
mkdir -p /tmp/pg-retest-blogs
cat > /tmp/pg-retest-blogs/shop-workload.sh <<'EOF'
#!/bin/bash
run_order() {
  local cid=$1 pid=$2 qty=$3
  docker exec -i blog-pg-source psql -U demo -d shop -q <<SQL >/dev/null
SELECT id, email FROM customers WHERE id = $cid;
SELECT sku, name, price_cents, stock FROM products WHERE id = $pid;
BEGIN;
INSERT INTO orders (customer_id, total_cents, status) VALUES ($cid, ${qty}999, 'pending');
WITH o AS (SELECT max(id) AS oid FROM orders WHERE customer_id = $cid)
INSERT INTO order_items (order_id, product_id, quantity, price_cents) SELECT oid, $pid, $qty, 999 FROM o;
COMMIT;
SELECT o.id, o.total_cents FROM orders o WHERE o.customer_id = $cid ORDER BY o.created_at DESC LIMIT 3;
SQL
}
for i in $(seq 1 30); do
  CID=$((1 + RANDOM % 500))
  PID=$((1 + RANDOM % 200))
  QTY=$((1 + RANDOM % 5))
  run_order $CID $PID $QTY
done
EOF
chmod +x /tmp/pg-retest-blogs/shop-workload.sh
/tmp/pg-retest-blogs/shop-workload.sh
```

Each iteration opens a fresh psql session, does two reads, opens a transaction, does two writes inside it, commits, then does another read. 30 iterations. A few seconds of runtime, a couple hundred queries in the log.

Confirm something actually happened:

```
$ docker exec blog-pg-source psql -U demo -d shop -tAc "SELECT count(*) FROM orders;"
31
```

The extra row is a smoke test I ran first. Not important.

## Step 6: Extract the CSV log and capture it

The log is inside the container at `/var/lib/postgresql/data/log/postgresql.csv`. Pull it to the host:

```bash
docker cp blog-pg-source:/var/lib/postgresql/data/log/postgresql.csv /tmp/pg-retest-blogs/source.csv
```

Quick peek at the format, because this is the single most important thing to get right when you're capturing for real:

```
$ grep "duration:" /tmp/pg-retest-blogs/source.csv | head -2
2026-04-14 13:26:47.892 UTC,"demo","shop",1234,"172.17.0.1:54210",69de...,1,"SELECT",...,0,LOG,00000,"duration: 0.584 ms  statement: SELECT id, email FROM customers WHERE id = 187",,,,,,,,,"psql","client backend",,0
```

See the `duration: X ms  statement: SELECT ...` part inside the quoted message field? That's what pg-retest wants. If that looks like `"statement: SELECT ..."` instead, with no duration prefix, your server logging is configured wrong and you'll get zero captured queries. Go back to Step 2.

Now capture:

```
$ ./target/release/pg-retest capture \
    --source-type pg-csv \
    --source-log /tmp/pg-retest-blogs/source.csv \
    --output /tmp/pg-retest-blogs/shop.wkl \
    --source-host blog-pg-source \
    --pg-version 16
2026-04-14T13:26:46.221773Z  INFO pg_retest: Captured 223 queries across 36 sessions
2026-04-14T13:26:46.221833Z  INFO pg_retest: Wrote workload profile to /tmp/pg-retest-blogs/shop.wkl
```

223 queries, 36 sessions. (Your numbers will differ by a handful because `$RANDOM` rolls different customer IDs on each run.) Each psql invocation counts as its own session. That matters in the next step because pg-retest replays one Tokio task per session, which means you get real concurrency back when you replay.

## Step 7: Inspect the workload profile

The `.wkl` file is MessagePack binary (tiny, around 20KB for what we just captured). You don't need to open it manually. pg-retest has an inspect command:

```
$ ./target/release/pg-retest inspect /tmp/pg-retest-blogs/shop.wkl | head -20
  Workload Profile Summary
  ========================

  Source host:      blog-pg-source
  PG version:       16
  Capture method:   csv_log
  Total sessions:   36
  Total queries:    223
  Captured at:      2026-04-14 13:26:46.221760363 UTC

  Session 1 - 7 queries
  Session 2 - 7 queries
  Session 3 - 7 queries
  Session 4 - 1 queries
  Session 5 - 7 queries
  Session 6 - 1 queries
```

You can see the shape of what got captured: most sessions are the 7-query shop flow (two selects, a begin, two inserts, a commit, a final select). The 1-query sessions are things like `psql` connecting to check server status during startup. You can also do `inspect --output-format json` and pipe it through `jq` if you want to peek at individual queries programmatically.

## Step 8: Replay against the target

The moment of truth:

```
$ ./target/release/pg-retest replay \
    --workload /tmp/pg-retest-blogs/shop.wkl \
    --target "host=localhost port=15501 user=demo password=demo dbname=shop" \
    --output /tmp/pg-retest-blogs/shop-replay.wkl
2026-04-14T13:27:02.411042Z  INFO pg_retest: Replaying 36 sessions (223 queries) against host=localhost port=15501 user=demo password=demo dbname=shop
2026-04-14T13:27:02.411059Z  INFO pg_retest: Mode: ReadWrite, Speed: 1x
2026-04-14T13:27:02.450173Z  INFO pg_retest: Replay complete: 223 queries replayed, 2 errors
2026-04-14T13:27:02.450268Z  INFO pg_retest: Results written to /tmp/pg-retest-blogs/shop-replay.wkl
```

Two things are worth unpacking here.

First, replay runs *concurrently*. 36 sessions, each on its own Tokio task with its own database connection, each walking through its own query list. pg-retest re-creates the session parallelism that existed at capture time. A serial replay would give garbage numbers because a serial workload has completely different contention characteristics from a concurrent one. If you care about benchmarks that mean anything, you care about session-level concurrency, and this is what gets you it.

Second, notice the `2 errors`. Don't panic. Let's look at them:

```
$ ./target/release/pg-retest replay \
    --workload /tmp/pg-retest-blogs/shop.wkl \
    --target "host=localhost port=15501 user=demo password=demo dbname=shop" \
    --output /tmp/pg-retest-blogs/shop-replay.wkl -v 2>&1 | grep -i error
DEBUG pg_retest::replay::session: Query error in session 6: ERROR: relation "customers" already exists
DEBUG pg_retest::replay::session: Query error in session 12: ERROR: database "shop" already exists
```

What happened: PG logs CSV rows for *everything*, including the `CREATE TABLE` and `CREATE DATABASE` statements I ran while seeding the source earlier. pg-retest faithfully captured those too, because it can't tell "setup DDL I accidentally ran in the capture window" apart from "application DDL I intentionally did." When you replay against the target (which already has the schema), those DDL statements hit an object that already exists and throw.

This is an entirely expected result, and it's the kind of teaching moment pg-retest shows you instead of hiding. Two options to avoid it in real captures:

1. Start your capture *after* you've set up the schema (e.g., rotate the PG log, or truncate it, before driving workload).
2. Use `--read-only` on replay to strip DML (and DDL falls out with it, since `--read-only` keeps only SELECT).

The replay ran 221 queries successfully and 2 hit expected errors. The transaction-aware replay engine auto-rolled-back the transactions containing the failed statements so nothing is left half-applied on the target. That's also intentional: if the capture had a real mid-transaction error, you want the same rollback behavior the application would have seen.

## Step 9: Compare source versus replay

This is the payoff step:

```
$ ./target/release/pg-retest compare \
    --source /tmp/pg-retest-blogs/shop.wkl \
    --replay /tmp/pg-retest-blogs/shop-replay.wkl
  pg-retest Comparison Report
  ===========================

  Metric               Source     Replay      Delta   Status
  ----------------------------------------------------------
  Total queries           223        223          0       OK
  Avg latency           0.4ms      1.0ms    +139.0%   SLOWER
  P50 latency           0.3ms      0.5ms     +62.9%   SLOWER
  P95 latency           0.6ms      2.2ms    +271.5%   SLOWER
  P99 latency           0.8ms     12.8ms   +1574.5%   SLOWER
  Errors                    0          2         +2     WARN

  Top 10 Regressions:
  ----------------------------------------------------------
  1. BEGIN; +196300.0% (0.0ms -> 11.8ms)
  2. BEGIN; +195816.7% (0.0ms -> 11.8ms)
  3. BEGIN; +20466.7% (0.0ms -> 1.2ms)
  ...
  9. INSERT INTO orders (customer_id, total_cents, stat +4303.4% (0.3ms -> 12.8ms)
  10. BEGIN; +4233.3% (0.0ms -> 0.3ms)

  Result: PASS
```

Everything got slower. Every single percentile regressed. Look at P99: 1574% slower. My benchmark must be ruined, right?

No. This is a great example of why you always read the full output. Look at the top regressions: almost all of them are `BEGIN`. Why would `BEGIN` be 196,000% slower? Because the source workload ran through psql connecting to PG via the Unix socket (sub-microsecond round trips), and the replay ran through pg-retest connecting via TCP to localhost:15501 (network stack, couple of milliseconds per round trip). The slowdown is network overhead on tiny statements, not an actual query regression. The `INSERT INTO orders` regression at position 9 is more interesting (0.3ms to 12.8ms) but the sample is too small to trust as a real signal.

This is also why comparing across "identical" setups isn't the point of pg-retest. The point is comparing a baseline replay against a *different* target: a new PG version, a different config, different hardware, different parameter group. You run the same captured workload through both, and the deltas between replay A and replay B tell you whether the change you made helped or hurt. The absolute numbers in a single replay mean much less than the relative delta between two replays.

The `Result: PASS` at the bottom comes from the threshold evaluator. Since we didn't pass `--thresholds`, the default thresholds tolerate anything, and it rubber-stamps the run as a pass. You can wire strict thresholds into a pipeline config file with specific p95, p99, and regression-count gates, and exit codes 0-5 that map to pass/fail/regression/error categories. That's how you'd use pg-retest in CI. Topic for another blog.

## What this gets you

You captured a real application-shaped workload. You replayed it concurrently against a second database. You have numbers. You have a comparison report. You have a `.wkl` file you can save forever and replay against any target you want, any time.

The value of this is not the first run. The first run is boring: you compared a database to a copy of itself. The value kicks in the second, fifth, fiftieth time you replay the same captured file against *different* targets. You change a `work_mem` setting, you replay. You turn on a JIT option, you replay. You upgrade from PG 16 to PG 17, you replay. Every replay is identical workload, so every measurement is comparable, and the deltas tell you whether your change was an improvement or a regression.

Things I intentionally left out of this post because they deserve their own write-ups: the wire-protocol proxy (zero log config required, captures more accurately from ORMs), workload scaling for capacity planning (take this 223-query workload, replay it 50x concurrently), AI-assisted tuning (pg-retest's tuner iterates over recommendations and auto-rolls back regressions), and AWS RDS capture (same code path, different input source). Those are coming.

For now, clean up your containers and pat yourself on the back:

```bash
docker rm -f blog-pg-source blog-pg-target
```

You just ran a real workload through a real capture-replay-compare cycle. That's a better benchmark than the one you were going to run next week.
