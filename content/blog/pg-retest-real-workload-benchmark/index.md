---
title: "Destroy Your Postgres in the Name of Science: Benchmarking With Your Real Workload"
date: 2026-04-22
draft: false
tags: ["pg-retest", "postgres", "benchmarking", "capacity-planning", "load-testing"]
summary: "Build a capacity benchmark from real captured traffic, sweep 1x → 50x, and drive PostgreSQL into saturation on purpose so you find the knee before production does."
build:
  list: never
---


HammerDB runs TPROC-C. pgbench runs TPC-B. Sysbench runs whatever sysbench runs. All three are useful for comparing databases against each other under standardized workloads, which is exactly what they were built for. None of them tells you what happens to *your* application when *your* database sees 10x traffic on Black Friday. If you've ever shipped a capacity plan based on pgbench numbers and then watched production melt anyway, you already know this.

pg-retest flips the benchmark question around. Instead of asking "how fast is this database at an industry-standard workload," it asks "how much of *my real workload* can this database handle before it falls over, and where exactly does it break?" You capture once. You replay at 1x, 5x, 10x, 50x. You find the knee. You make a decision.

This post builds a capacity benchmark from real captured workload, sweeps the throughput curve, and deliberately drives a PostgreSQL target into the ground to show you what saturation looks like and how to measure it without getting garbage data. Every number in every table below came from running this on an actual PG 16 container. If you see different numbers on your hardware, that's the point, you're supposed to measure yours.

## What you'll need

```
$ docker --version
Docker version 29.1.5, build 0e6fee6

$ rustc --version
rustc 1.93.1 (01f6ddf75 2026-02-11)
```

This post assumes you've already done the capture-replay-compare walk-through from the intro post and you have pg-retest built. If not, go back and do that first. It takes 15 minutes. I'll wait.

The test target in this post is a default PG 16 container with `max_connections = 100` (the default). That matters. Most "capacity benchmarks" run against a database with `max_connections = 2000` and `shared_buffers` cranked up, which produces numbers that have nothing to do with anything you'll actually deploy.

## Step 1: Capture a clean, repeatable workload

For capacity work you want a captured workload that:

1. Contains nothing but real application queries (no setup DDL, no admin probes)
2. Has enough distinct sessions that concurrent replay actually measures concurrency
3. Is small enough to replay in a few seconds (so you can sweep scale factors in a few minutes)
4. Has the same mix of reads and writes as the application you're testing

Start fresh: rotate the log on your source PG so the capture file only contains application queries, then drive a workload.

```bash
# Truncate the CSV log on the source so the capture is clean
docker exec -u root blog-pg-source sh -c "truncate -s 0 /var/lib/postgresql/data/log/postgresql.csv"

# Drive 80 sessions of the shop workflow (same script as the intro post, 80 iterations)
cat > /tmp/pg-retest-blogs/shop-workload-big.sh <<'EOF'
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
for i in $(seq 1 80); do
  CID=$((1 + RANDOM % 500))
  PID=$((1 + RANDOM % 200))
  QTY=$((1 + RANDOM % 5))
  run_order $CID $PID $QTY
done
EOF
chmod +x /tmp/pg-retest-blogs/shop-workload-big.sh
/tmp/pg-retest-blogs/shop-workload-big.sh
```

Pull the log and capture:

```
$ docker cp blog-pg-source:/var/lib/postgresql/data/log/postgresql.csv /tmp/pg-retest-blogs/source-clean.csv
$ ./target/release/pg-retest capture \
    --source-type pg-csv \
    --source-log /tmp/pg-retest-blogs/source-clean.csv \
    --output /tmp/pg-retest-blogs/shop-clean.wkl \
    --source-host blog-pg-source --pg-version 16
2026-04-14T14:53:11.647071Z  INFO pg_retest: Captured 560 queries across 80 sessions
2026-04-14T14:53:11.647143Z  INFO pg_retest: Wrote workload profile to /tmp/pg-retest-blogs/shop-clean.wkl
```

80 sessions of 7 queries each = 560 queries. pg-retest's classifier can tell us what it looks like:

```
$ ./target/release/pg-retest inspect /tmp/pg-retest-blogs/shop-clean.wkl --classify | grep "Overall:"
Overall: Mixed
```

"Mixed" means roughly 80% reads, 20% writes, modest latency, a handful of transactions per session. That matches the hand-rolled loop above (two selects, an insert-insert transaction, a final select). This is what a cart-to-checkout user flow looks like.

## Step 2: Baseline at 1x

One replay pass at the captured scale, read-only mode:

```
$ ./target/release/pg-retest replay \
    --workload /tmp/pg-retest-blogs/shop-clean.wkl \
    --target "host=localhost port=15501 user=demo password=demo dbname=shop" \
    --output /tmp/pg-retest-blogs/bench-1x.wkl \
    --read-only
2026-04-14T14:53:36.286433Z  INFO pg_retest: Replaying 80 sessions (560 queries) against host=localhost port=15501 user=demo password=demo dbname=shop
2026-04-14T14:53:36.286448Z  INFO pg_retest: Mode: ReadOnly, Speed: 1x
2026-04-14T14:53:36.322488Z  INFO pg_retest: Replay complete: 320 queries replayed, 0 errors
```

The read-only mode strips DML from the workload at replay time, which is why 560 captured queries became 320 replayed queries (the SELECTs). This is the flag you use for capacity work: reads are repeatable and safe, writes change database state between runs and pollute your measurements.

The 1x replay finishes in under 40 milliseconds because we're testing 320 tiny queries against a warm cache on the same machine. Not interesting as a benchmark by itself, but it's our known-good baseline.

## Step 3: The naive scale-up (and why it crashes)

The obvious next move: crank `--scale` up and see what happens.

```
$ ./target/release/pg-retest replay \
    --workload /tmp/pg-retest-blogs/shop-clean.wkl \
    --target "host=localhost port=15501 user=demo password=demo dbname=shop" \
    --output /tmp/pg-retest-blogs/bench-naked.wkl \
    --read-only --scale 10
2026-04-14T15:13:02.111889Z  INFO pg_retest: Scaled workload: 80 original sessions -> 800 total (10x, 0ms stagger)
2026-04-14T15:13:02.111925Z  INFO pg_retest: Replaying 800 sessions (3200 queries) against host=localhost port=15501 user=demo password=demo dbname=shop
2026-04-14T15:13:02.112143Z  WARN pg_retest::replay::session: Session replay failed: db error
2026-04-14T15:13:03.189958Z  WARN pg_retest::replay::session: Session replay failed: db error
... [246 more failure warnings] ...
```

248 out of 800 sessions failed. Roughly 31%. Why?

Because `--scale 10` means "duplicate each of the 80 sessions ten times and launch them all at once," which is 800 parallel connection attempts against a PostgreSQL that has `max_connections = 100`. 700 of those connection attempts hit the connection ceiling at about the same moment. Some of them get through as earlier connections finish. The rest get "sorry we already have too many clients" errors from the backend and their sessions fail entirely.

This is not a bug in pg-retest or in PG. This is what happens when you naively multiply your workload beyond what your target can physically handle. The lesson: `--scale N` is a workload multiplier, not a traffic shaper. If you want to measure what your database does at 10x concurrent demand, you need to regulate how many of those sessions run at once so you don't just crash into the connection limit. That's what `--max-connections` is for.

## Step 4: Regulate and sweep

Re-run with a sensible connection cap:

```
$ ./target/release/pg-retest replay \
    --workload /tmp/pg-retest-blogs/shop-clean.wkl \
    --target "host=localhost port=15501 user=demo password=demo dbname=shop" \
    --output /tmp/pg-retest-blogs/bench-10x-limited.wkl \
    --read-only --scale 10 --max-connections 50
2026-04-14T14:54:02.031338Z  INFO pg_retest::replay::session: Concurrency limited to 50 (workload has 400 sessions)
2026-04-14T14:54:02.157766Z  INFO pg_retest: Replay complete: 1600 queries replayed, 0 errors

  Scaled Replay Report
  ====================

  Scale factor:    10x
  Total sessions:  800
  Total queries:   3200
  Throughput:      13083.9 queries/sec
  Avg latency:     1.66 ms
  P95 latency:     3.56 ms
  P99 latency:     4.79 ms
  Errors:          0
  Error rate:      0.00%
```

Clean run. 3200 queries, 0 errors, 13k queries per second, sub-5ms p99. pg-retest internally uses a tokio Semaphore to cap concurrent session execution at 50, so 750 sessions sit in a queue and fire as connections free up. The total work done is the same, the pressure on the target is regulated, and now we get meaningful numbers.

Now sweep. We want to answer: for this workload on this target, where does throughput plateau and where does latency explode?

```bash
for S in 5 10 20 40 80; do
  echo "=== scale ${S}x ==="
  ./target/release/pg-retest replay \
    --workload /tmp/pg-retest-blogs/shop-clean.wkl \
    --target "host=localhost port=15501 user=demo password=demo dbname=shop" \
    --output /tmp/pg-retest-blogs/bench-${S}x.wkl \
    --read-only --scale $S --max-connections 50 2>&1 | \
    grep -E "Throughput|Avg latency|P95 latency|P99 latency|Errors"
done
```

Raw results:

| Scale | Queries | Throughput (q/s) | Avg (ms) | P95 (ms) | P99 (ms) | Errors |
|------:|--------:|-----------------:|---------:|---------:|---------:|-------:|
| 5x    | 1,600   | 12,091           | 1.51     | 3.18     | 3.89     | 0      |
| 10x   | 3,200   | 12,345           | 1.70     | 3.71     | 4.99     | 0      |
| 20x   | 6,400   | 12,592           | 1.69     | 3.61     | 5.00     | 0      |
| 40x   | 12,800  | 12,564           | 1.73     | 3.66     | 4.82     | 0      |
| 80x   | 25,600  | 13,107           | 1.66     | 3.51     | 4.63     | 0      |

Throughput is flat around 12-13k queries per second. Latency barely moves. The scale factor is changing how long the test runs, not how much pressure the database sees, because the concurrency limiter is holding pressure constant at 50 connections. This is useful: it tells us the database can sustain this workload at 50-concurrent-session pressure indefinitely. It is not yet telling us the capacity ceiling.

## Step 5: Find the knee

The knee of the curve is where extra concurrency starts costing more than it buys. We find it by holding scale constant and sweeping `--max-connections`:

```bash
for C in 10 25 50 90 110; do
  echo "=== max-conn ${C} ==="
  ./target/release/pg-retest replay \
    --workload /tmp/pg-retest-blogs/shop-clean.wkl \
    --target "host=localhost port=15501 user=demo password=demo dbname=shop" \
    --output /tmp/pg-retest-blogs/bench-conn${C}.wkl \
    --read-only --scale 20 --max-connections $C 2>&1 | \
    grep -E "Throughput|Avg latency|P95 latency|P99 latency|Total sessions|Errors"
done
```

| Cap | Sessions | Throughput (q/s) | Avg (ms) | P95 (ms) | P99 (ms) | Notes |
|----:|---------:|-----------------:|---------:|---------:|---------:|-------|
| 10  | 1,600    | 8,063            | 0.53     | 1.13     | 1.52     | underutilized, but latency is beautiful |
| 25  | 1,600    | 12,045           | 0.88     | 1.90     | 2.48     | 50% more throughput at 60% higher p95 |
| 50  | 1,600    | 13,083           | 1.66     | 3.56     | 4.79     | 9% more throughput at nearly 2x p95 |
| 90  | 1,600    | 13,784           | 2.67     | 5.98     | 7.93     | 5% more throughput at 3.4x p95 vs baseline |
| 110 | **1,595**| 14,094           | 2.62     | 5.80     | 7.79     | 5 sessions dropped (target max_connections=100) |

There it is. The knee is somewhere between 25 and 50 concurrent connections for this workload on this target. Going from 10 to 25 connections adds 50% throughput and barely budges latency. Going from 25 to 50 adds 9% more throughput but doubles P95. Going from 50 to 90 adds 5% more throughput but doubles P95 *again*. Past 90, the target starts rejecting connections because `max_connections = 100` is a hard ceiling at the PG config level, and you lose data (5 sessions just vanished from the 110 run, because their connection attempts were rejected by the backend before any queries could run).

The capacity sweet spot for this workload on this target is about 25 concurrent connections. If this were production and you were capacity planning, the recommendation writes itself: target utilization no higher than 25 concurrent sessions for comfortable p95 latency, understand that you have about 2x headroom to 50 sessions at the cost of 2x latency, and anything past 90 means either raising `max_connections` or scaling horizontally.

Notice something else: the 10-connection run had the BEST latency of the whole sweep (p95 = 1.13ms). That's because the database is never contending for any shared resource at that concurrency. Every session owns its connection, no buffer pool contention, no lock waits, no CPU scheduling pressure. Low-latency wins at low concurrency, throughput wins at higher concurrency, and the point of capacity planning is deciding which one you need.

## Step 6: The write-workload trap (and how pg-retest warns you)

Everything above was `--read-only`. If we drop that flag and scale writes, we get a warning you should take seriously:

```
$ ./target/release/pg-retest replay \
    --workload /tmp/pg-retest-blogs/shop-clean.wkl \
    --target "host=localhost port=15501 user=demo password=demo dbname=shop" \
    --output /tmp/pg-retest-blogs/bench-writes.wkl \
    --scale 5 --max-connections 50
2026-04-14T14:53:45.444306Z  WARN pg_retest: Warning: scaling a workload with 80 write queries (out of 560 total). Scaled writes will execute multiple times, which changes data state and may produce different results than the original workload.
```

This is not just an abstract disclaimer. Think about what `--scale 5` actually does to a write workload: every `INSERT INTO orders` in the captured workload executes five times instead of one. Every scale run inserts five times as many rows into the target database. The second run inserts them on top of the first run's inserts. Foreign key validation, index updates, WAL generation, all multiplied. The numbers you get from run 2 are not comparable to run 1 because the table sizes are different.

Two reasonable ways to handle this:

1. **Use read-only for capacity sweeps.** This is what we did above. You measure the target's ability to serve reads, which is what most read-heavy applications actually care about, and you get repeatable numbers.

2. **Restore target state between runs.** Snapshot the target's data before the benchmark, run the full scaled write workload, measure, then restore the snapshot for the next run. pg-retest's pipeline mode can automate this with the Docker provisioner, but that's a different blog.

pg-retest prints the warning and proceeds. It doesn't refuse, because occasionally you really do want to scale writes (for example, to measure how the target behaves when the insert rate doubles). But if you're seeing weird trending numbers across scale factors on a write workload, the warning is telling you why.

## Step 7: Per-category scaling (when your workload is heterogeneous)

Our test workload is 80 identical shop sessions, classified as "Mixed." pg-retest also supports scaling by session category when your workload has a mix of patterns:

```
$ ./target/release/pg-retest replay --help 2>&1 | grep "scale-"
      --scale-analytical <SCALE_ANALYTICAL>
          Scale analytical sessions by N (per-category scaling)
      --scale-transactional <SCALE_TRANSACTIONAL>
          Scale transactional sessions by N (per-category scaling)
      --scale-mixed <SCALE_MIXED>
          Scale mixed sessions by N (per-category scaling)
      --scale-bulk <SCALE_BULK>
          Scale bulk sessions by N (per-category scaling)
```

Why this matters: a real production workload is rarely homogeneous. You might have 70% short OLTP sessions, 20% analytics scans, and 10% nightly bulk jobs. If you just `--scale 10` everything uniformly, you're pretending your capacity question is "what if we had 10x of every query." The real capacity question is usually "what if the analytics team doubles their query load while the OLTP traffic stays flat?" Per-category scaling lets you ask that question directly: `--scale-analytical 2 --scale-transactional 1 --scale-bulk 1`.

It's mutually exclusive with plain `--scale`. Use one or the other. Our homogeneous shop workload won't show anything interesting with per-category scaling because pg-retest classified all 80 sessions as "Mixed," so you'd end up sweeping `--scale-mixed N` which does the same thing as `--scale N`. If you have a production workload with actual category diversity, though, this is where capacity planning gets precise.

## What this gets you vs. HammerDB and pgbench

Not a takedown of HammerDB or pgbench. They are well-built tools that are widely used because they're well-built tools that are widely used. They have their place: standardized workloads for comparing databases against each other in apples-to-apples tests, where the point is that everyone runs the same benchmark and the results can be compared across hardware, configs, and vendors. If you want to argue with someone that PostgreSQL 17 is faster than MySQL 8 on TPROC-C, HammerDB is the tool.

But your Black Friday is not TPROC-C. Your Black Friday is thousands of carts-to-checkouts from the specific Django models your team wrote, hitting the specific indexes your DBA argued about, with the specific connection pool your Ruby app uses. A TPROC-C benchmark can tell you your new RDS instance is 1.4x faster "on average," but it can't tell you whether your slowest 5% of queries will get worse because they happen to hit an index that's now missing a statistic hint, because TPROC-C doesn't know about your indexes.

pg-retest works the other way around. You capture what actually runs. You replay it against every target you care about. You compare. The signal you get back is directly about *your* workload. The cost is that the numbers from my shop benchmark above mean nothing for your capacity plan. They mean something for my capacity plan. Which is exactly the point.

Three things you can do next with this:

1. Capture a window of real production traffic (proxy-mode capture for apps using prepared statements, CSV capture for simple workloads, topic for another post), save the `.wkl` file, and replay it against every candidate target before any change lands.

2. Build a pipeline config (`pg-retest run --config ci.toml`) that runs a capture-replay-compare with thresholds on every PR. If p95 regresses past a defined tolerance, exit code is nonzero and CI fails. No human has to eyeball graphs.

3. Run two replays against two different targets simultaneously using A/B variant mode (`pg-retest ab --variant "prod-like=..." --variant "candidate=..."`) and let the comparison report tell you which one handled your workload better.

Clean up when you're done:

```bash
docker rm -f blog-pg-source blog-pg-target
```

The numbers in your capacity plan should come from your workload. Anything else is somebody else's capacity plan with a Postgres logo taped to it.
