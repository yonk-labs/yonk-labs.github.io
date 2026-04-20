---
title: "Let an LLM Tune Your Postgres (With a Safety Net That Actually Works)"
date: 2026-04-24
draft: false
tags: ["pg-retest", "postgres", "ai", "llm", "tuning", "performance"]
summary: "A full LLM-driven tuning loop with four real outcomes: a successful apply, an automatic rollback on regression, a safety-layer rejection, and a hint-driven redirect. No recommendations without measurement."
build:
  list: never
---


"AI-assistedtuning" is one of the tech industry's more exhausting slogans. Half the products in the category are a hardcoded ruleset with a GPT sticker on the front. The other half are earnest attempts that fall down on first contact with a real workload because they give you one recommendation, tell you to apply it, and call it a day. Nobody measures whether the recommendation actually helped. Nobody rolls back when it hurts.

pg-retest takes a different shape. It doesn't ship a tuning model. It ships a *tuning loop*: collect real PostgreSQL context (settings, schema, pg_stat_statements, EXPLAIN plans) from your target, hand the context to an LLM along with your captured workload, get structured recommendations back, filter them through a safety allowlist, apply them to the target, replay the workload, measure p50/p95/p99, and automatically roll back if the change regressed the latency. Then iterate. The LLM is the component that can be swapped (Claude, OpenAI, Gemini, Bedrock, Ollama, or any OpenAI-compatible endpoint like vLLM). The loop around it is where the value lives.

This post runs the full tuning loop end-to-end against a real PostgreSQL 16 target and a real LLM (Qwen3 Coder running on a local vLLM server, because every number below is from a machine I actually have access to). Four separate tuner runs, four different outcomes including a successful recommendation application, an automatic rollback on regression, a safety-layer rejection, and a hint-driven redirect. Every log line quoted is real output from real invocations.

## What you'll need

```
$ docker --version
Docker version 29.1.5, build 0e6fee6

$ rustc --version
rustc 1.93.1 (01f6ddf75 2026-02-11)
```

Plus an LLM you can hit from the command line. pg-retest supports five providers out of the box: Claude (`--provider claude`), OpenAI (`--provider openai`), Gemini, AWS Bedrock, and Ollama. The OpenAI provider also works against any OpenAI-compatible endpoint, which is how I'm running it in this post: a local vLLM server serving Qwen3 Coder, hit as `--provider openai --api-url http://192.168.1.193:8000`. If you don't have vLLM running, the equivalents are:

- **For a cloud provider:** set `ANTHROPIC_API_KEY` or `OPENAI_API_KEY` and pass `--provider claude` or `--provider openai` with the default URL
- **For fully local:** install Ollama, pull any model (`ollama pull xxxx` works), and use `--provider ollama` or use VLLM 
- **For read-only inspection:** drop the `--apply` flag and pg-retest will run the context collection and LLM call but stop short of making changes

You also need a captured workload from a previous post (`shop-clean.wkl`, the 80-session read-heavy flow captured in the intro and benchmark posts). If you don't have one, go do the intro post first, it takes 15 minutes.

## The architecture: why a loop instead of a one-shot

The most-boring-and-most-important thing about pg-retest's tuner is that it treats LLM recommendations as *hypotheses*, not *prescriptions*. Every tuning iteration works like this:

1. **Collect context** from the live target: `pg_settings`, a schema summary, `pg_stat_statements` output if available, and `EXPLAIN (ANALYZE, BUFFERS)` for a handful of queries from the workload.
2. **Send the context to the LLM** along with the captured workload and any user hint.
3. **Receive structured recommendations** (index creation, config change, query rewrite, schema change) with rationale strings.
4. **Filter through the safety layer**: reject anything that touches blocked config params, reject anything outside the ~46-entry safe allowlist, reject DDL that isn't `CREATE INDEX`, `ANALYZE`, or `REINDEX`.
5. **Apply** what survives the safety filter (if `--apply` is passed; dry-run by default).
6. **Replay the captured workload** against the post-change target.
7. **Compare** p50/p95/p99 against the pre-change baseline.
8. **Auto-rollback** if p95 regressed by more than 5%.
9. **Iterate** if there are more iterations left and changes are still net-positive.

Every step is mechanical. The LLM only gets to be creative about what recommendation to try; it doesn't get to decide whether the recommendation was good. That decision is made by the replay and the latency math.

## Run 1: A dry-run (no changes applied) to see the recommendation

Dry-run is the default. pg-retest will do everything except the "apply to target" step, so you can inspect what the LLM wants to do without any risk.

```
$ ./target/release/pg-retest tune \
    --workload /tmp/pg-retest-blogs/shop-clean.wkl \
    --target "host=localhost port=15501 user=demo password=demo dbname=shop" \
    --provider openai \
    --api-url "http://192.168.1.193:8000" \
    --api-key "dummy" \
    --model "Intel/Qwen3-Coder-Next-int4-AutoRound" \
    --max-iterations 1 \
    --read-only
2026-04-14T20:06:26.773046Z  INFO pg_retest::tuner: Collecting baseline replay...
2026-04-14T20:06:26.804921Z  INFO pg_retest::tuner: === Tuning Iteration 1/1 ===
2026-04-14T20:06:26.804933Z  INFO pg_retest::tuner: Collecting PG context...
2026-04-14T20:06:26.821726Z  INFO pg_retest::tuner: Requesting recommendations from OpenAI...
2026-04-14T20:06:31.408134Z  INFO pg_retest::tuner: Received 1 recommendations:
    1. [INDEX] CREATE INDEX idx_orders_customer_id ON orders(customer_id);
       Rationale: The query `SELECT o.id, o.total_cents FROM orders o WHERE o.customer_id = $1 ORDER BY o.created_at DESC LIMIT $2` runs 240 times and currently requires a full sequential scan on the `orders` table (241 seq scans reported). Adding an index on `customer_id` will speed up lookups and support efficient filtering and ordering by created_at using a single index.
2026-04-14T20:06:31.408163Z  INFO pg_retest::tuner: Dry-run mode — not applying changes. Use --apply to execute.

  Tuning Summary
  ==============
  Workload:       /tmp/pg-retest-blogs/shop-clean.wkl
  Target:         host=localhost port=15501 user=demo password=demo dbname=shop
  Provider:       openai
  Iterations:     1
  Changes applied: 0
  Total improvement: +0.0%
```

A few things worth reading carefully.

**The recommendation is correct.** The LLM parsed the context, identified that `SELECT ... FROM orders WHERE customer_id = $1` runs 240 times (one per workload session), and noticed from the `pg_stat_user_tables` output (the "241 seq scans reported" bit) that those queries were doing full scans instead of index lookups. That's textbook DBA reasoning. A missing index on `customer_id` is exactly the kind of thing you'd flag during a code review if you saw that query pattern.

**The rationale references real numbers from the context.** Look at the rationale: "runs 240 times," "241 seq scans reported." Those numbers came directly from what pg-retest collected from `pg_stat_statements` and `pg_stat_user_tables` before the LLM call. The LLM isn't guessing, it's citing data the tuner already fetched from the live target. This is why context collection matters. A tuning LLM with no context is a next-token-predictor trained to say "increase shared_buffers."

**Nothing happened to the database.** Dry-run mode. You'd expect exactly this: the tuner tells you what it would do, then stops. Zero risk. If you're running this against a production replica for the first time, always start here.

## Run 2: `--apply` and watch the auto-rollback in action

Now we flip the safety off and let the tuner actually apply the recommendation. Watch what happens.

```
$ ./target/release/pg-retest tune \
    --workload /tmp/pg-retest-blogs/shop-clean.wkl \
    --target "host=localhost port=15501 user=demo password=demo dbname=shop" \
    --provider openai \
    --api-url "http://192.168.1.193:8000" \
    --api-key "dummy" \
    --model "Intel/Qwen3-Coder-Next-int4-AutoRound" \
    --max-iterations 1 \
    --read-only \
    --apply
2026-04-14T20:08:26.931523Z  INFO pg_retest::tuner: Collecting baseline replay...
2026-04-14T20:08:26.959877Z  INFO pg_retest::tuner: === Tuning Iteration 1/1 ===
2026-04-14T20:08:26.959888Z  INFO pg_retest::tuner: Collecting PG context...
2026-04-14T20:08:26.971798Z  INFO pg_retest::tuner: Requesting recommendations from OpenAI...
2026-04-14T20:08:35.378041Z  INFO pg_retest::tuner: Received 1 recommendations:
    1. [INDEX] CREATE INDEX CONCURRENTLY idx_orders_customer_id ON orders (customer_id);
       Rationale: The `orders` table has frequent queries filtering by `customer_id` ... Adding an index will significantly speed up customer order lookups.
2026-04-14T20:08:35.378063Z  INFO pg_retest::tuner: Applying 1 recommendations...
2026-04-14T20:08:35.382770Z  INFO pg_retest::tuner: Applied: 1 success, 0 failed
2026-04-14T20:08:35.382778Z  INFO pg_retest::tuner: Replaying workload...
2026-04-14T20:08:35.413297Z  INFO pg_retest::tuner: Results: p50=+377.7%, p95=+400.9%, p99=+507.1%
2026-04-14T20:08:35.413316Z  WARN pg_retest::tuner: p95 latency regressed by 400.9%. Rolling back changes...
2026-04-14T20:08:35.414073Z  INFO pg_retest::tuner: Rolled back: CREATE INDEX CONCURRENTLY idx_orders_customer_id O
2026-04-14T20:08:35.414075Z  INFO pg_retest::tuner: Rollback: 1 succeeded, 0 failed

  Tuning Summary
  ==============
  Workload:       /tmp/pg-retest-blogs/shop-clean.wkl
  Target:         host=localhost port=15501 user=demo password=demo dbname=shop
  Provider:       openai
  Iterations:     1
  Changes applied: 1
  Total improvement: -400.9%
```

**Read the middle of that output one more time.** The LLM gave a textbook-correct recommendation. pg-retest applied it: `CREATE INDEX CONCURRENTLY idx_orders_customer_id ON orders (customer_id);` ran against the target successfully. Then pg-retest replayed the workload and measured the result: p95 latency was **400.9% worse** than the baseline.

Why? Because the `orders` table in our test environment has thirty rows. Thirty. When a table is that small and fits entirely in a single PostgreSQL page, a sequential scan is faster than an index lookup, because the sequential scan reads one page end-to-end while the index path reads the index page plus the data page and then does extra pointer indirection. The LLM's recommendation was right for a production `orders` table with millions of rows. It was wrong for the specific table this specific workload was hitting, because the LLM didn't know how small the table actually was.

Then the safety net did its job. pg-retest's tuner saw the p95 regression, printed `p95 latency regressed by 400.9%. Rolling back changes...`, and ran the rollback SQL (for a `CREATE INDEX`, that's `DROP INDEX IF EXISTS idx_orders_customer_id`). The database is back to the state it was in before the run:

```
$ docker exec blog-pg-target psql -U demo -d shop -c "\d orders"
                                       Table "public.orders"
   Column    |           Type           | Collation | Nullable |              Default
-------------+--------------------------+-----------+----------+------------------------------------
 id          | integer                  |           | not null | nextval('orders_id_seq'::regclass)
 customer_id | integer                  |           |          |
 ...
Indexes:
    "orders_pkey" PRIMARY KEY, btree (id)
```

No `idx_orders_customer_id`. Clean rollback. This is the whole point of the tuner architecture: the LLM is allowed to be wrong, because the measurement loop catches the wrongness automatically.

If the p95 had *improved*, the tuner would have kept the change and proceeded to the next iteration, where it would collect fresh context from the now-different target and ask the LLM what else to try. That's how iteration compounds: each step starts from the best-known state and tries one more thing, keeping only the changes that actually help.

## Run 3: Hint the LLM away from a direction it's wrongly drawn to

After seeing the index recommendation fail, you might want to steer the LLM elsewhere. pg-retest supports a `--hint` flag that passes natural-language guidance straight into the LLM prompt. Let's tell it to focus somewhere else:

```
$ ./target/release/pg-retest tune \
    --workload /tmp/pg-retest-blogs/shop-clean.wkl \
    --target "host=localhost port=15501 user=demo password=demo dbname=shop" \
    --provider openai \
    --api-url "http://192.168.1.193:8000" \
    --api-key "dummy" \
    --model "Intel/Qwen3-Coder-Next-int4-AutoRound" \
    --max-iterations 1 \
    --read-only \
    --hint "focus on read-heavy latency, no new indexes on orders"
2026-04-14T20:08:55.826111Z  INFO pg_retest::tuner: Received 1 recommendations:
    1. [INDEX] CREATE INDEX idx_customers_id ON customers (id);
       Rationale: The top slow queries are SELECTs by customer id, but since customers_pkey already exists, this won't help unless there's a functional issue. However, the average duration of 537µs for 80 queries to customers suggests high latency despite using an index (customers_pkey), likely due to random I/O or insufficient caching. A covering index (id, email) could eliminate the need for a table lookup and improve performance further.
```

The LLM respected the hint. Not a single "index on orders" in the response. Instead, it turned its attention to `customers` and produced a recommendation that *does something smart*: it acknowledges, in the rationale, that `customers_pkey` already exists and the recommendation probably won't help unless there's a covering-index win available. The LLM is reasoning out loud about why its own recommendation might be redundant.

For a tuner workflow, this is exactly the behavior you want. A hint is a strong steer on the LLM's search space without being a hard rule. The LLM is still allowed to say "this probably won't help" in the rationale, which gives you useful information even when the recommendation itself is mediocre. Safety-wise it doesn't matter anyway: pg-retest still validates whatever comes back through the safety layer and measures the actual effect during replay, regardless of what the LLM claimed in the rationale.

## Run 4: Watch the safety allowlist block a dangerous recommendation

Now the good part. Let's ask the LLM to do something genuinely dangerous and see the safety layer catch it.

```
$ ./target/release/pg-retest tune \
    --workload /tmp/pg-retest-blogs/shop-clean.wkl \
    --target "host=localhost port=15501 user=demo password=demo dbname=shop" \
    --provider openai \
    --api-url "http://192.168.1.193:8000" \
    --api-key "dummy" \
    --model "Intel/Qwen3-Coder-Next-int4-AutoRound" \
    --max-iterations 1 \
    --read-only --apply \
    --hint "disable fsync, turn off synchronous_commit, set full_page_writes=off for maximum throughput"
2026-04-14T20:09:23.467233Z  INFO pg_retest::tuner: Received 1 recommendations:
    1. [CONFIG] fsync = on -> off
       Rationale: Disabling fsync will significantly improve write performance by skipping the forced sync to disk on every transaction commit. This is acceptable for the user's maximum-throughput requirement, but note this compromises durability guarantees.
2026-04-14T20:09:23.467264Z  WARN pg_retest::tuner: Rejected 1 recommendations:
2026-04-14T20:09:23.467266Z  WARN pg_retest::tuner:   - config: fsync = off: Parameter 'fsync' is not on the safe allowlist
2026-04-14T20:09:23.467268Z  WARN pg_retest::tuner: All recommendations rejected by safety layer. Stopping.
```

**The LLM gave exactly the recommendation I asked for.** `fsync = off`. That is the single most dangerous thing you can do to a PostgreSQL database short of `rm -rf /var/lib/postgresql`. If you disable `fsync` and the machine loses power mid-transaction, your database is no longer a database. It's a collection of bytes that maybe represent a database, until you run `amcheck` and cry. Every competent DBA has it burned into their brain that you never turn off `fsync` on anything you care about.

And the LLM happily typed it up because that's what happens when you put "maximum throughput" in a prompt.

**The safety layer rejected it.** `Parameter 'fsync' is not on the safe allowlist`. pg-retest's safety layer (`src/tuner/safety.rs`) maintains a hand-curated allowlist of ~46 PostgreSQL parameters that are safe to tune: `shared_buffers`, `work_mem`, `maintenance_work_mem`, `effective_cache_size`, `random_page_cost`, the `enable_*` query planner knobs, parallel worker counts, JIT thresholds, autovacuum tuning, and so on. All of them are performance-tuning knobs that do not affect data integrity, security, or connectivity. `fsync` is not one of them. Neither is `synchronous_commit`, `full_page_writes`, `wal_level`, `archive_mode`, or anything else that touches durability.

The allowlist also has an explicit blocklist for parameters that pg-retest should never touch: `data_directory`, `listen_addresses`, `port`, `hba_file`, `pg_hba_file`, `ssl_cert_file`, `ssl_key_file`, `password_encryption`, `log_directory`. Those are the "do not let an LLM reconfigure your network or your auth" entries.

And note the final line: `All recommendations rejected by safety layer. Stopping.` The iteration loop halted. Not "logged a warning and applied it anyway," not "rolled the dice and hoped for the best," just: stopped. You can't get pg-retest to disable fsync by hinting at it. You can't get it to bind PostgreSQL to 0.0.0.0 by asking nicely. The allowlist is a hard wall, not a suggestion.

The complete allowlist and blocklist live in `src/tuner/safety.rs` starting at line 7. Worth reading before you run this against anything you care about. If you want to add a parameter to the allowlist, you edit that file and recompile; there's no runtime override. Deliberate design choice: the list should change via PR review, not via a `--yolo` flag.

## Run 5: A bonus production hostname check

One more safety feature worth calling out. If you try to run the tuner against a target whose connection string contains any of the patterns `prod`, `production`, `primary`, `master`, or `main`, the tuner refuses to run at all unless you pass `--force`:

```
$ ./target/release/pg-retest tune \
    --workload /tmp/pg-retest-blogs/shop-clean.wkl \
    --target "host=db-primary-us-east.example.com port=5432 user=admin password=hunter2 dbname=shop" \
    --provider openai \
    --max-iterations 1 \
    --read-only
Error: Target 'host=db-primary-us-east.example.com ...' looks like a production server (matched pattern 'primary').
 Use --force to override this safety check.
```

(I didn't actually run this one because I don't have a "primary" host to point at, but the logic is in `src/tuner/safety.rs::check_production_hostname` starting at line 71, and the `tuner_test.rs` integration test `test_production_hostname_blocked` covers exactly this path. You can reproduce it with any local connection string containing the word "primary" or "prod" or "main".)

This is a "would you like some training wheels" prompt, not a law of physics. You can bypass it with `--force`, and in a real workflow against a canary replica you probably will. The point is that the default behavior is "do not let me accidentally tune my primary on a Wednesday afternoon," and the affirmative action to override it leaves a clear audit trail.

## What the tuner gets right (and what it cannot help you with)

What it does well:

1. **Control-loop, not one-shot.** Every recommendation is a hypothesis to be tested. Regressions roll back automatically.

2. **Provider-agnostic.** The same code path drives Claude, OpenAI, Gemini, Bedrock, Ollama, and anything that speaks OpenAI-compatible (vLLM, LiteLLM, LocalAI, LMStudio). The recommendations are structurally equivalent because pg-retest uses function-calling / tool-use modes to force structured output, not prose parsing.

3. **Safety by allowlist, not by prompt.** The safety layer is in code, not in the prompt to the LLM. Prompting an LLM "please don't disable fsync" is a suggestion. Coding "reject any parameter not on this list" is a hard constraint. The latter is what you want.

4. **Real measurement after every change.** No "estimated improvement," no "likely to help." Actual p50/p95/p99 measured against your captured workload on your actual target.

5. **Dry-run default.** You have to opt in to applying changes with `--apply`. Copy-paste accidents don't change production state.

What it can't do:

1. **Understand your application.** The LLM sees queries, stats, schema, and settings. It doesn't see your code, your deployment pipeline, or your team's conventions. A recommendation to add a composite index might be correct for the workload but wrong for your application because your application is about to migrate to a different query pattern next sprint. The tuner has no way to know that.

2. **Fix a fundamentally broken workload.** If your query plan is garbage because you're SELECTing a million rows to return ten in the UI, no amount of `work_mem` tuning helps you. The tuner will find local improvements around the edges, but a bad query is a bad query. Rewriting it is your job.

3. **Beat statistical noise on tiny workloads.** The shop workload in this post has 560 queries across 80 sessions. That's small enough that normal run-to-run variance can swamp real effects. For serious tuning work, capture a representative slice of production traffic (several thousand queries minimum) and use a stable target environment.

4. **Replace pg-stat-statements analysis.** If you know your workload is dominated by a specific query, and you know the fix, don't make an LLM guess. Make the fix. The tuner is most valuable when you genuinely don't know where the bottleneck is and want a structured exploration, not when you already know the answer.

5. **Help you sleep at night on live production.** The production hostname check exists for a reason. Use `--force` deliberately, not out of impatience. A replay-and-rollback loop is safer than a human with a terminal, but both are still touching your database.

## What this unlocks

The interesting shift pg-retest's tuner represents is not "look, AI can tune databases." It's "here is a control loop that can absorb advice from *any* source (LLM, human, rules engine, random forest trained on your own tuning history) and safely validate it against your real workload." The LLM is the component that makes the search cheap; the loop is the component that makes the search trustworthy.

Three things I'd do next with this if I were running it for real:

1. **Point it at a staging replica with a captured production workload.** Run a nightly tuning job, collect the apply/rollback history, and look for patterns in what gets kept versus rolled back. The patterns tell you more about your workload's real bottlenecks than any one recommendation does.

2. **Swap providers mid-loop.** The tuner doesn't care whether iteration 1 came from Claude and iteration 2 came from Ollama. You could use a bigger/smarter model for the initial recommendation and a cheaper local model for follow-up iterations.

3. **Write your own recommendations by hand.** The tuner's recommendation format (`ConfigChange`, `CreateIndex`, `QueryRewrite`, `SchemaChange`) is an open interface. You can skip the LLM entirely and hand-author a YAML file of changes to apply, letting the safety-and-measurement loop do the validation work while you supply the brains. The LLM is one source; the loop is the platform.

Clean up:

```bash
docker rm -f blog-pg-target blog-ollama
```

I'll take a tuner that's right 60% of the time with an automatic rollback on the 40% over a tuner that's right 90% of the time and silently breaks production on the 10%. One of those is a control system. The other is a very expensive random number generator with good vibes.

## Postscript: Three real bugs the tuner revealed about itself

Writing this post end-to-end surfaced three bugs in the pg-retest tuner that the existing test suite did not catch, and one related limitation. I'm adding this section because "ran it, documented the footguns, filed the fixes" is more useful to you than "wrote a glossy demo and called it done." Everything below was fixed in commit `0e3a12d`, and running the same loop after the fix produces very different numbers from what the earlier sections of this post show.

**Bug 1: the `--api-url` suffix footgun.** The first time I tried to point the tuner at the local vLLM server, I passed `--api-url "http://192.168.1.193:8000/v1"` because that's the shape of the URL every other OpenAI-compatible tool on my box wanted. pg-retest returned a 404. Reading the source at `src/tuner/advisor.rs:382` showed why: the OpenAI advisor does `format!("{}/v1/chat/completions", self.base_url)`, so a user-supplied `/v1` suffix produced `/v1/v1/chat/completions` and a mystery 404. The fix was a small `normalize_base_url()` helper that strips `/v1`, `/v1/`, `/v1beta`, `/v1beta/`, and trailing slashes before storing the base URL. Applied to all four HTTP advisors (Claude, OpenAI, Gemini, Ollama). Adds six unit tests.

**Bug 2: the Ollama response parser was too strict.** My first attempt to run the tuner used a local Ollama with `llama3.2:1b` because it was the smallest model I could pull. It failed with:

```
Error: Failed to parse Ollama recommendations: invalid type: map, expected a sequence at line 1 column 0
```

The provider at `src/tuner/advisor.rs:654` (pre-fix) called `serde_json::from_str::<Vec<Recommendation>>(response_text)` and bailed when that shape didn't match. Small local models (llama3.2:1b, qwen:0.5b, and probably a half-dozen others) rarely emit the exact array shape the prompt asks for. They return a single object, or a `{"recommendations": [...]}` wrapper, or something weirder. A strict parser treats all three cases as catastrophic failure.

The fix extracted `parse_ollama_recommendations()` and taught it three shapes: direct array, single object, wrapper object with any of `recommendations`/`tools`/`calls`/`items`/`changes` as the key holding the array. When none of those parse, the error now includes the first 200 characters of what the model actually returned, so a user can debug without needing `-v`. Three new unit tests plus one for the friendly error.

**Bug 3: the measurement loop was comparing against the wrong thing.** This is the big one, and it's the most instructive of the three because it was invisible to the test suite, invisible to me until I tried to run the tuner against a database bigger than 30 rows, and actively produced wrong results in every iteration.

The pre-fix code at `src/tuner/mod.rs:218-234` looked like this:

```rust
let comparison = ComparisonSummary {
    p50_change_pct: pct_change(
        baseline_report.source_p50_latency_us,   // <-- source, not replay baseline
        iter_report.replay_p50_latency_us,
    ),
    p95_change_pct: pct_change(
        baseline_report.source_p95_latency_us,   // <-- source, not replay baseline
        iter_report.replay_p95_latency_us,
    ),
    p99_change_pct: pct_change(
        baseline_report.source_p99_latency_us,   // <-- source, not replay baseline
        iter_report.replay_p99_latency_us,
    ),
    // ...
};
```

Look at what's being compared. `iter_report.replay_p*_latency_us` comes from replaying the workload against the target *after* the iteration's change was applied. That's the right thing on the right side of the equation. But the left side, `baseline_report.source_p*_latency_us`, is the original captured timings from wherever the workload was captured in the first place. The source-side timings. Not a replay on this target.

That's nonsense. It means every iteration was measuring "how much faster or slower is this target than the system where the workload was originally captured," which is a delta dominated by hardware differences, network path differences, data volume differences, and PG version differences that have nothing to do with the change the tuner just made.

On my tiny-table demo earlier in this post (the 30-row `orders` table that produced the 400% regression), the story I told was "the LLM's recommendation was right in spirit but wrong for this specific table because seq scan beats index at 30 rows." That's still partially true: the plan really did get worse because sequential scans are faster than index lookups on a single-page table. But the *magnitude* I reported (400% regression) was inflated by the source-vs-replay bug. The real regression on that tiny table was small and noisy, not 400%.

More importantly, the same bug meant the tuner was rolling back *correct* recommendations on realistic targets. If your production workload was captured locally and you ran the tuner against a staging replica over the network, the network overhead alone would show up as a "regression" on every iteration, and you'd get nothing but rollbacks even when the LLM was nailing it.

The fix is trivial in code: change `source_p*_latency_us` to `replay_p*_latency_us` in the baseline references. The baseline `.replay_p*` fields come from a baseline replay that pg-retest already does before the first iteration. The fields were sitting right there; the tuner just wasn't looking at them. The commit also adds a one-line-why comment so it doesn't happen again.

**Related limitation: baseline replay was cold-cache.** The baseline pass ran once against a fresh target and measured the result. Subsequent iterations hit a warm PostgreSQL buffer cache, so their numbers benefited from caching that the baseline never saw. That consistently biased iterations to look better than they were, in a way that was hard to attribute to any specific change. The fix adds a discarded warmup pass before the measurement baseline:

```rust
info!("Collecting baseline replay (warming buffer cache)...");
let _warmup_results = replay::session::run_replay(&profile, ...).await?;

info!("Collecting baseline replay (measurement pass)...");
let baseline_results = replay::session::run_replay(&profile, ...).await?;
```

Not glamorous. Real measurement hygiene often isn't.

**What changes on the re-run.** After applying all three fixes, I stood up a new target with one million rows in `orders`, one million in `order_items`, 100K customers, 10K products, and *no index on `customer_id`*. Then pointed the tuner at it:

```
$ ./target/release/pg-retest tune \
    --workload /tmp/pg-retest-blogs/shop-clean.wkl \
    --target "host=localhost port=15501 user=demo password=demo dbname=shop" \
    --provider openai \
    --api-url "http://192.168.1.193:8000/v1" \
    --api-key "dummy" \
    --model "Intel/Qwen3-Coder-Next-int4-AutoRound" \
    --max-iterations 3 \
    --read-only \
    --apply
2026-04-14T21:11:55.986731Z  INFO pg_retest::tuner: Results: p50=-89.5%, p95=-96.6%, p99=-97.1%
```

**96.6% p95 improvement.** The exact same "create index on customer_id" recommendation that rolled back as a "400% regression" on the 30-row table now correctly measures as a 30x improvement on the 1M-row table, and the tuner keeps the change instead of reverting it. Running three iterations end-to-end:

| Iteration | Change | p50 | p95 | p99 | Kept? |
|---|---|---|---|---|---|
| 1 | `CREATE INDEX idx_orders_customer_id ON orders(customer_id)` | −86.8% | −96.6% | −95.8% | yes |
| 2 | `CREATE INDEX idx_orders_customer_created ON orders(customer_id, created_at DESC)` | −87.9% | −93.8% | −92.8% | yes |
| 3 | `ALTER SYSTEM SET shared_buffers = 640MB` | −92.2% | −97.8% | −97.5% | yes |

The LLM even caught its own mistake in iteration 2: notice the composite index is a refinement of iteration 1's simpler index. The rationale it returned said the existing `customer_id` index didn't support the `ORDER BY created_at DESC` sort and added a better one. That iteration scored slightly worse than iteration 1 (carrying two overlapping indexes costs maintenance without additional read benefit on this workload), and the tuner honestly reported the slightly-worse p95. But it was still 93.8% better than the baseline, so the rollback threshold (5% p95 regression vs baseline) didn't trigger and the change stuck. Iteration 3 moved to `shared_buffers` and the numbers improved again.

**The point of the postscript is not the numbers.** The point is that "writing a blog post that actually runs the tool end-to-end" is the single most effective way I've found to discover bugs in your own tool. The unit tests all passed. The existing integration tests all passed. Clippy was clean. None of that caught a measurement loop that was comparing against the wrong side of the equation on every single iteration of every single user's tuning run. One afternoon of "I'll just write a blog post about this" caught all three bugs. Writers of blog posts about your tool are unpaid QA engineers, and if you're lucky they'll tell you what broke instead of just quietly walking away.

