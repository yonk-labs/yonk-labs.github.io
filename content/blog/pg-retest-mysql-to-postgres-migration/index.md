---
title: "Moving MySQL to Postgres Without Praying on Cutover Day"
date: 2026-04-27
draft: false
tags: ["pg-retest", "postgres", "mysql", "migration"]
summary: "Capture your real MySQL slow log, push it through a MySQL→Postgres transform pipeline, and replay against Postgres. Every failure in replay is one you don't find in production."
build:
  list: never
---


I've done this migration enough times to have opinions about it. Most MySQL-to-Postgres guides spend 80% of their word count on schema conversion and the last 20% is "and then you test with representative traffic." The 20% is where all the pain lives, and the guides handle it in a sentence.

Here's the thing. Schema is solved. pgloader does the bulk load and handles the MySQL-specific type casts; a couple dozen Stack Overflow answers cover the remaining edge cases. Your schema will land on Postgres in a few hours of work. That's not where cutover blows up.

Cutover blows up because of your queries. Backticks. `LIMIT 5, 10` offsets. `IFNULL`. `IF(cond, a, b)`. `UNIX_TIMESTAMP`. All legal MySQL syntax, none of it valid Postgres, all of it buried across 200-plus files in your application code. You'll find maybe half with grep. The rest you discover at 2 AM on cutover day, with your VP of Engineering on the Zoom, watching the rollback decision tree light up in real time.

I built a subcommand in `pg-retest` for exactly this problem. Takes a MySQL slow query log, parses the actual queries your app ran, pushes them through a regex-based transform pipeline that handles the common MySQL-to-Postgres divergences, and replays the transformed queries against a real Postgres target. Every failure in replay is one you don't find in production.

This post walks the whole loop: MySQL in Docker, a workload that looks like a real MySQL app, capture the slow log, transform, replay against Postgres, count the damage. Every command ran on an actual setup and produced the output you see.

## What you'll need

```
$ docker --version
Docker version 29.1.5, build 0e6fee6

$ rustc --version
rustc 1.93.1 (01f6ddf75 2026-02-11)
```

`pg-retest` built with `cargo build --release`. MySQL and Postgres come in containers. First pull on mysql:8.0 takes a minute or two because the image is a few hundred megabytes compressed and Oracle still hasn't figured out trimming.

## Step 1: MySQL with the slow log cranked to 11

`long_query_time=0` logs every query — which is what you want for capture, not for production. `log_output=FILE` writes to a real file on disk instead of the `slow_log` system table, so we can pull it off the container with `docker cp`.

```bash
docker run -d --name blog-mysql-source -p 13306:3306 \
  -e MYSQL_ROOT_PASSWORD=demo -e MYSQL_DATABASE=shop \
  -e MYSQL_USER=demo -e MYSQL_PASSWORD=demo \
  mysql:8.0 \
  --slow_query_log=ON \
  --slow_query_log_file=/var/lib/mysql/slow.log \
  --long_query_time=0 \
  --log_output=FILE
```

MySQL takes 15-20 seconds to come up on first start. The entrypoint is seeding the `mysql` system database, creating your user, and running internal setup. Be patient or you'll get connection refused and think something's broken.

And yes — MySQL will shriek "Using a password on the command line interface can be insecure" at you for every single command for the rest of your life. You can make it stop by setting up a client config file. I'm not doing that for a blog post. It's MySQL's version of a "hello fellow kids" sticker and I'm going to ignore it from here on out.

Check it's alive:

```
$ docker exec blog-mysql-source mysqladmin -u root -pdemo ping
mysqladmin: [Warning] Using a password on the command line interface can be insecure.
mysqld is alive

$ docker exec blog-mysql-source mysql -u demo -pdemo shop -e "SELECT VERSION();"
VERSION()
8.0.45
```

**One real gotcha before we move on.** With `long_query_time=0`, *every* query gets logged, including MySQL's own bootstrap traffic on container startup: `SELECT @@version_comment`, `TRUNCATE TABLE time_zone`, `INSERT INTO mysql.time_zone_name`, hundreds more. These end up in the slow log alongside your application queries. `pg-retest` will cheerfully try to transform and replay them later, and most will fail because they reference MySQL system variables and system tables that don't exist on Postgres.

You've got three options:

1. Narrow your capture window — rotate the slow log after MySQL finishes initializing, drive your workload, then capture.
2. Raise `long_query_time` to something like `0.01` so most internal queries fall below the threshold.
3. Eat the noise and let the transform pipeline skip what it doesn't recognize.

I'm going with option 3 because the failures are instructive. They show you exactly where the regex pipeline runs out of runway.

## Step 2: The schema

```bash
docker exec blog-mysql-source mysql -u demo -pdemo shop -e "
CREATE TABLE customers (
  id INT AUTO_INCREMENT PRIMARY KEY,
  email VARCHAR(200) NOT NULL UNIQUE,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE products (
  id INT AUTO_INCREMENT PRIMARY KEY,
  sku VARCHAR(100) NOT NULL UNIQUE,
  name VARCHAR(200) NOT NULL,
  price_cents INT NOT NULL,
  stock INT NOT NULL
);
CREATE TABLE orders (
  id INT AUTO_INCREMENT PRIMARY KEY,
  customer_id INT,
  total_cents INT NOT NULL,
  status VARCHAR(30) NOT NULL DEFAULT 'pending',
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (customer_id) REFERENCES customers(id)
);
CREATE TABLE order_items (
  id INT AUTO_INCREMENT PRIMARY KEY,
  order_id INT,
  product_id INT,
  quantity INT NOT NULL,
  price_cents INT NOT NULL,
  FOREIGN KEY (order_id) REFERENCES orders(id),
  FOREIGN KEY (product_id) REFERENCES products(id)
);
CREATE INDEX idx_orders_customer ON orders(customer_id);
CREATE INDEX idx_orders_status ON orders(status);
"
```

Seed 500 customers and 200 products using a recursive CTE so the data has some variety (yes, MySQL 8 has recursive CTEs — it was the one feature they finally shipped after everyone else had it for a decade):

```bash
docker exec blog-mysql-source mysql -u demo -pdemo shop -e "
INSERT INTO customers (email)
  WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n < 500)
  SELECT CONCAT('user', n, '@shop.test') FROM seq;

INSERT INTO products (sku, name, price_cents, stock)
  WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n < 200)
  SELECT CONCAT('SKU', n), CONCAT('Product ', n),
         (100 + n * 11) MOD 9900 + 100,
         50 + n MOD 300
  FROM seq;

SELECT COUNT(*) FROM customers;
SELECT COUNT(*) FROM products;
"
```

```
COUNT(*)
500
COUNT(*)
200
```

## Step 3: Drive a workload that looks like a real MySQL app

For the transform pipeline to do anything interesting, the workload has to actually use MySQL-specific syntax. If your app writes pure ANSI SQL, congratulations, you don't need this post. In the real world, MySQL apps are soaked in MySQL-isms: backtick-quoted identifiers, `IFNULL` for null handling, `IF(cond, a, b)` for inline conditionals, `LIMIT offset, count`, `UNIX_TIMESTAMP` for epoch conversion, `LAST_INSERT_ID()` after an insert. I've worked with maybe 200 MySQL applications across my time at MySQL AB and Percona, and I don't think I've seen one that avoided all of these.

Workload script:

```bash
cat > /tmp/pg-retest-blogs/mysql-workload.sh <<'EOF'
#!/bin/bash
run_order() {
  local cid=$1 pid=$2 qty=$3
  docker exec -i blog-mysql-source mysql -u demo -pdemo shop <<SQL >/dev/null 2>&1
SELECT \`id\`, \`email\` FROM \`customers\` WHERE \`id\` = $cid;
SELECT \`sku\`, IFNULL(\`name\`, 'unknown') AS name, \`price_cents\`
  FROM \`products\` WHERE \`id\` = $pid LIMIT 0, 1;
SELECT \`id\`, UNIX_TIMESTAMP(\`created_at\`) AS ts
  FROM \`orders\` WHERE \`customer_id\` = $cid
  ORDER BY \`created_at\` DESC LIMIT 5;
INSERT INTO \`orders\` (\`customer_id\`, \`total_cents\`, \`status\`)
  VALUES ($cid, ${qty}999, 'pending');
INSERT INTO \`order_items\` (\`order_id\`, \`product_id\`, \`quantity\`, \`price_cents\`)
  VALUES (LAST_INSERT_ID(), $pid, $qty, 999);
SELECT IF(\`total_cents\` > 1000, 'big', 'small') AS tier, COUNT(*)
  FROM \`orders\` WHERE \`customer_id\` = $cid
  GROUP BY tier LIMIT 0, 10;
SQL
}
for i in $(seq 1 40); do
  CID=$((1 + RANDOM % 500))
  PID=$((1 + RANDOM % 200))
  QTY=$((1 + RANDOM % 5))
  run_order $CID $PID $QTY
done
EOF
chmod +x /tmp/pg-retest-blogs/mysql-workload.sh
/tmp/pg-retest-blogs/mysql-workload.sh
```

Did it do anything?

```
$ docker exec blog-mysql-source mysql -u demo -pdemo shop -e "SELECT COUNT(*) FROM orders;"
COUNT(*)
40
```

40 orders. 40 application-driven sessions. Six SQL statements per session, each session hitting at least four different MySQL-specific syntax patterns. That's our raw material: 240 application queries sitting inside a slow log that also contains several thousand MySQL-internal queries we don't care about.

## Step 4: Pull the slow log and capture

Copy it off the container:

```bash
docker cp blog-mysql-source:/var/lib/mysql/slow.log /tmp/pg-retest-blogs/mysql-slow.log
```

The MySQL slow log format is not CSV, not JSON, not anything ANSI-standard. It's MySQL's own freeform text format with sections headed by `# Time:`, `# User@Host:`, `# Query_time:` lines. Been that way since the Sun days and nobody's going to fix it now. `pg-retest` parses it via `--source-type mysql-slow`:

```
$ ./target/release/pg-retest capture \
    --source-type mysql-slow \
    --source-log /tmp/pg-retest-blogs/mysql-slow.log \
    --output /tmp/pg-retest-blogs/shop-mysql.wkl \
    --source-host blog-mysql-source \
    --pg-version 8.0
  Transform Report
  ================
  Total queries:  9250
  Transformed:    242
  Unchanged:      9004
  Skipped:        4

  Skipped queries:
    - use shop;
select @@version_comment limit 1;
      Reason: MySQL-specific command: use shop;
select @@version_comment limit
    - SET autocommit = 1;
      Reason: MySQL-specific command: SET autocommit = 1;
    - FLUSH PRIVILEGES;
      Reason: MySQL-specific command: FLUSH PRIVILEGES;
    - use mysql;
select @@version_comment limit 1;
      Reason: MySQL-specific command: use mysql;
select @@version_comment limi
2026-04-14T15:47:34.170218Z  INFO pg_retest: Captured 9246 queries across 47 sessions
2026-04-14T15:47:34.175613Z  INFO pg_retest: Wrote workload profile to /tmp/pg-retest-blogs/shop-mysql.wkl
```

A few things to unpack.

**9,250 total queries.** Way more than the 40 × 6 = 240 we drove ourselves. The rest is MySQL's bootstrap traffic getting logged at `long_query_time=0`. This is the noise I flagged in Step 1.

**242 transformed.** These are the queries that contained backticks, `LIMIT x, y`, `IFNULL`, `IF()`, or `UNIX_TIMESTAMP`. Roughly matches what we expected — 40 iterations × ~6 MySQL-ism queries each, plus a handful of internal queries that happened to match a pattern.

**9,004 unchanged.** Most queries in any slow log are already ANSI-compatible (`SELECT 1`, `COMMIT`, `SET timestamp=...`). The pipeline passes these through untouched. No transform needed.

**4 skipped.** MySQL-specific commands the pipeline recognizes as impossible to translate: `USE`, `SET autocommit`, `FLUSH PRIVILEGES`. `pg-retest` strips them. You don't want `USE shop` running against a Postgres target anyway — you'd get a weird syntax error that would waste 20 minutes of your life.

## Step 5: What the transforms actually look like

This is the trust-but-verify part. Raw MySQL from the slow log, versus what ended up in the workload profile. Note that the IDs differ between raw and transformed examples — the script picks random customer and product IDs each iteration, so I'm grabbing queries from different sessions. The syntax is what matters.

**Transform 1: backticks + IFNULL + LIMIT offset,count, all in one query**

Raw MySQL:
```sql
SELECT `sku`, IFNULL(`name`, 'unknown') AS name, `price_cents`
  FROM `products` WHERE `id` = 9 LIMIT 0, 1;
```

Transformed:
```sql
SELECT "sku", COALESCE("name", 'unknown') AS name, "price_cents"
  FROM "products" WHERE "id" = 132 LIMIT 1 OFFSET 0;
```

Three substitutions in one pass. Backticks to double-quotes. `IFNULL` to `COALESCE` (same semantics, different name, blame the ANSI committee). `LIMIT 0, 1` — MySQL's "offset then count" argument order — to `LIMIT 1 OFFSET 0`, which is the spec-compliant "count then offset" order. All three preserve meaning exactly.

**Transform 2: UNIX_TIMESTAMP**

Raw MySQL:
```sql
SELECT `id`, UNIX_TIMESTAMP(`created_at`) AS ts
  FROM `orders` WHERE `customer_id` = 260
  ORDER BY `created_at` DESC LIMIT 5;
```

Transformed:
```sql
SELECT "id", EXTRACT(EPOCH FROM "created_at")::bigint AS ts
  FROM "orders" WHERE "customer_id" = 204
  ORDER BY "created_at" DESC LIMIT 5;
```

`UNIX_TIMESTAMP(ts)` becomes `EXTRACT(EPOCH FROM ts)::bigint`. The cast is there because `EXTRACT(EPOCH FROM ...)` returns a double precision in Postgres, and MySQL's `UNIX_TIMESTAMP` — for a non-fractional `DATETIME` — returns an integer. The cast preserves original semantics for whole-second timestamps. This is the kind of thing that eats an afternoon when you port queries by hand.

One caveat worth flagging: if your MySQL `DATETIME` columns have fractional-second precision, `UNIX_TIMESTAMP` returns a `DECIMAL` and the `::bigint` cast truncates those fractional seconds. If you care about sub-second precision, swap the cast to `::numeric` by hand in the workload profile before replay.

**Transform 3: IF() to CASE WHEN**

Raw MySQL:
```sql
SELECT IF(`total_cents` > 1000, 'big', 'small') AS tier, COUNT(*)
  FROM `orders` WHERE `customer_id` = 260
  GROUP BY tier LIMIT 0, 10;
```

Transformed:
```sql
SELECT CASE WHEN "total_cents" > 1000 THEN 'big' ELSE 'small' END AS tier,
       COUNT(*)
  FROM "orders" WHERE "customer_id" = 204
  GROUP BY tier LIMIT 10 OFFSET 0;
```

`IF(cond, then, else)` becomes the spec form `CASE WHEN cond THEN then ELSE else END`, and the `LIMIT x, y` → `LIMIT y OFFSET x` rewrite shows up again.

## Step 6: Replay against a real Postgres target

Stand up a Postgres target with an equivalent schema — `AUTO_INCREMENT` becomes `SERIAL`, `VARCHAR` becomes `TEXT` because Postgres doesn't care, `TIMESTAMP` becomes `TIMESTAMPTZ` because you should almost always use `TIMESTAMPTZ`:

```bash
docker run -d --name blog-pg-target -p 15501:5432 \
  -e POSTGRES_PASSWORD=demo -e POSTGRES_USER=demo -e POSTGRES_DB=shop \
  postgres:17

# give it a few seconds

docker exec blog-pg-target psql -U demo -d shop -c "
CREATE TABLE customers (id SERIAL PRIMARY KEY, email TEXT UNIQUE NOT NULL, created_at TIMESTAMPTZ DEFAULT now());
CREATE TABLE products (id SERIAL PRIMARY KEY, sku TEXT UNIQUE NOT NULL, name TEXT NOT NULL, price_cents INTEGER NOT NULL, stock INTEGER NOT NULL);
CREATE TABLE orders (id SERIAL PRIMARY KEY, customer_id INTEGER REFERENCES customers, total_cents INTEGER NOT NULL, status TEXT NOT NULL DEFAULT 'pending', created_at TIMESTAMPTZ DEFAULT now());
CREATE TABLE order_items (id SERIAL PRIMARY KEY, order_id INTEGER REFERENCES orders, product_id INTEGER REFERENCES products, quantity INTEGER NOT NULL, price_cents INTEGER NOT NULL);
INSERT INTO customers (email) SELECT 'user'||g||'@shop.test' FROM generate_series(1,500) g;
INSERT INTO products (sku, name, price_cents, stock) SELECT 'SKU'||g, 'Product '||g, (100+g*11)%9900+100, 50+g%300 FROM generate_series(1,200) g;
"
```

Now replay the captured and transformed workload against Postgres, read-only:

```
$ ./target/release/pg-retest replay \
    --workload /tmp/pg-retest-blogs/shop-mysql.wkl \
    --target "host=localhost port=15501 user=demo password=demo dbname=shop" \
    --output /tmp/pg-retest-blogs/mysql-replay.wkl \
    --read-only
2026-04-14T15:48:15.748714Z  INFO pg_retest: Replaying 47 sessions (9246 queries) against host=localhost port=15501 user=demo password=demo dbname=shop
2026-04-14T15:48:15.748732Z  INFO pg_retest: Mode: ReadOnly, Speed: 1x
2026-04-14T15:49:01.495056Z  INFO pg_retest: Replay complete: 214 queries replayed, 50 errors
```

214 queries ran, 50 errored. Two questions. What are the errors, and why only 214 out of 9,246?

The second one's easy. `--read-only` strips DML at replay time and keeps only SELECTs. Out of 9,246 captured queries, only 214 were SELECTs. Most of the rest were internal `INSERT INTO mysql.time_zone_name` and friends that got filtered. Of the 214 SELECTs, 50 failed, 164 succeeded.

The first one is more interesting.

```
$ ./target/release/pg-retest replay \
    --workload /tmp/pg-retest-blogs/shop-mysql.wkl \
    --target "host=localhost port=15501 user=demo password=demo dbname=shop" \
    --output /tmp/pg-retest-blogs/mysql-replay2.wkl \
    --read-only -v 2>&1 | grep "Query error" | head -5
DEBUG pg_retest::replay::session: Query error in session 21: ERROR: column "version_comment" does not exist
DEBUG pg_retest::replay::session: Query error in session 10: ERROR: column "version_comment" does not exist
DEBUG pg_retest::replay::session: Query error in session 54: ERROR: column "version_comment" does not exist
DEBUG pg_retest::replay::session: Query error in session 38: ERROR: column "version_comment" does not exist
DEBUG pg_retest::replay::session: Query error in session 13: ERROR: column "datadir" does not exist
```

All 50 errors are variations on the same theme: MySQL's `SELECT @@version_comment` and similar system-variable queries from the bootstrap traffic. The regex pipeline saw `@@version_comment`, didn't recognize it as a MySQL system variable (because there's nothing in the pattern catalog for it — because Postgres has no equivalent), and passed it through. Postgres then tried to interpret `@@version_comment` as a column reference and gave up. Exactly the limitation the docs warn about: the pipeline covers 80-90% of real application SQL and deliberately leaves MySQL system variables and server-side functions with no Postgres equivalent alone.

**The real signal here isn't the 50 errors. It's the 164 successes.** 164 SELECTs from the simulated shop, using backticks, `IFNULL`, `IF()`, `UNIX_TIMESTAMP`, and MySQL's `LIMIT offset, count` syntax, all transformed automatically, all replayed against Postgres, zero manual rewrites. Hand-porting 164 queries gets you maybe an afternoon of work and two subtle bugs you won't find until production. This gets you the same result in a few minutes with evidence.

## Where the pipeline runs out of runway

The transform is regex-based. No SQL AST, no parser. That buys you speed and robustness — a regex won't choke on a query it doesn't fully understand, it just passes through untouched — but it costs you coverage on edge cases. The ones that matter:

**MySQL system variables.** `@@version`, `@@autocommit`, `@@global.max_connections`. No Postgres equivalent. The transform passes them through, Postgres rejects them. Filter them out of your slow log before capture, or just ignore them in the replay output.

**`LAST_INSERT_ID()`.** This one isn't in the regex catalog and it matters. Your workload probably uses it — MySQL apps reach for it constantly after an `INSERT` to get the auto-increment value. Postgres has no `LAST_INSERT_ID()`; you use `RETURNING id` on the insert or `currval('seq_name')` after. If you're running a non-read-only replay against Postgres, every `LAST_INSERT_ID()` call fails. The fix is in your application code, not in the transform pipeline — and the failures showing up in replay are how you find the callsites.

**Stored procedures and triggers.** The transform works at the query level. It does not translate `CREATE PROCEDURE`, DELIMITER blocks, or MySQL-flavored trigger bodies. If your application logic lives in stored procs, you have a larger porting problem and `pg-retest` helps with the queries the app sends *around* the procs, not the procs themselves.

**MySQL-specific functions without a Postgres equivalent.** `GROUP_CONCAT` (use `STRING_AGG`), `FROM_UNIXTIME` with format strings, `DATE_FORMAT` with MySQL-specific format codes. Some have close Postgres equivalents, some don't, and the pipeline covers the ones I've hit most often in production workloads. Look at `src/transform/mysql_to_pg.rs` for the full list.

**Regex-based backtick replacement inside string literals.** A query like `SELECT 'a \`backtick\` in a string'` will get its literal backticks rewritten to double-quotes. In practice I've never seen this in real MySQL app code — nobody writes SQL with literal backticks inside strings — but the foot-gun is there if you hit it. Hand-edit the workload profile or skip that query.

The honest answer to "what doesn't the pipeline do" is: *it doesn't replace testing*. It replaces the first 80% of hand-porting the obvious stuff. You still replay the transformed workload against a real target and read the errors. That's the whole exercise.

## Where this fits

This isn't a migration tool. It's a migration *validation* tool, and that distinction matters.

The actual migration plan is five steps. Port the schema with pgloader or whatever schema-conversion path you prefer — `pg-retest` doesn't help here and won't pretend to. Turn on MySQL slow query logging on a production-adjacent instance for a capture window that looks like real traffic (a day, a week, whatever matches your app's cycle). Capture with `pg-retest` and read the transform report. Replay against your Postgres target and study the error list — every error is either a query that needs manual porting in your app code, MySQL-internal noise you can ignore, or a genuine schema mismatch. Fix category one, iterate. Cut over once the remaining errors are all category two.

`pg-retest` is the measurement tool in that loop. It doesn't write the migration, doesn't convert the schema, doesn't handle your deploy. It tells you which queries break before production tells you in a way that costs money.

Clean up:

```bash
docker rm -f blog-mysql-source blog-pg-target
```

Most MySQL-to-Postgres guides treat "test with representative traffic" as a footnote. It's the whole job. If your last migration went clean on cutover day and you didn't do something like this, you got lucky. Lucky is not a strategy.
