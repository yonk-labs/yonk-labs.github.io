---
title: "Training Sets for LoRA: How to Teach a 4B Model to Write Postgres SQL Without Crying"
date: 2026-04-13
draft: false
tags: ["nl2sql", "postgres", "ai", "llm", "lora", "fine-tuning", "pg_agents"]
summary: "A layered training corpus — domain pairs, public ballast, and a reusable Postgres syntax corpus — is 80% of the work for a NL2SQL LoRA. The training config is YAML and patience."
---

*Part 3 of a series on making AI actually useful against real databases. Start with [Part 1: Why LLMs Fail at NL2SQL](../why-llms-fail-at-nl2sql/) and [Part 2: Building Your Semantic Layer](../building-your-semantic-layer/).*

A 4-billion-parameter language model can, in theory, learn to write SQL for your database in an afternoon on a single GPU. Whether the SQL it learns to write is any *good* is almost entirely a function of what you feed it. Not the model. Not the optimizer. Not the LoRA rank you obsessed over for two days. The training set.

I've been heads-down on a LoRA training pipeline for the last few weeks, and I want to walk through what's actually involved, because there's a lot of "fine-tune your LLM on your data" advice floating around that conveniently skips the part where you have to *build the data*. Which is the actual job. Everything else is YAML and patience.

Let me start with the boring background, because I have to, and then we'll get into the fun stuff.

---

## What LoRA Is, Without the Math PhD

LoRA stands for Low-Rank Adaptation, and the elevator pitch is this: instead of updating all 4 billion parameters in your base model when you fine-tune it, you freeze them, then bolt on two tiny matrices to specific layers and only train those. The two small matrices, when multiplied together, produce a low-rank approximation of what a full weight update *would* have looked like. Rank 16 is typical. Rank 32 if you're feeling spicy.

What that means in practice:

* You train maybe 30 million parameters instead of 4 billion. About 0.7%.
* The whole adapter weighs ~50 MB on disk, not 8 GB.
* You can train one in an hour on a single GPU, not a week on a cluster.
* At inference time you can either keep the adapter as a sidecar (and hot-swap it in and out) or merge it back into the base weights for zero overhead.

The clever part is the math. The useful part is everything else. You get most of the behavior change of a full fine-tune at a fraction of the cost, *and* you can iterate fast enough that the training corpus becomes the variable you actually optimize. Which, as we'll see, is the right thing to be optimizing.

---

## Why LoRA Is Practically Tailor-Made for NL2SQL

Here's something nobody seems to say out loud about NL2SQL fine-tuning: you are not teaching the model a new language. It already speaks SQL. It already speaks English. It knows what `JOIN` does. It knows what a `GROUP BY` is for. What it *doesn't* know is the specific dialect, the idiomatic Postgres flavor, the conventions of how your particular schema names things, and how to map fuzzy human questions into all of that consistently.

That's a narrow shift, not a new skill. Which makes it basically the textbook use case for low-rank adaptation.

Three reasons LoRA is the right tool for this job:

**Reason one: you're nudging, not rewriting.** You want the model to lean into Postgres syntax over MySQL syntax, prefer your idiomatic JOIN paths over hallucinated ones, and stop reaching for `LIMIT 10` on every query just because most of its training data did. That's a steering wheel, not an engine swap. LoRA is built for steering.

**Reason two: iteration speed matters more than peak quality.** Fine-tuning a model on an NL2SQL corpus and discovering that you forgot to include any `LATERAL` joins in your training data is the kind of mistake you only catch by running the eval. If each iteration costs you a week of GPU time, you'll iterate twice and ship something mediocre. If each iteration costs an hour, you'll run twenty experiments before lunch on Friday and ship something that actually works.

**Reason three: you can stack adapters in production.** This is the operationally beautiful bit. One base model on disk. Twenty different LoRA adapters loaded on demand, one per customer or per schema or per agent. Want a per-tenant fine-tune without running twenty model copies? Done. Try doing that with full fine-tunes and your infra bill will give you a heart attack.

So the tool is right. Now we need to talk about ammunition.

---

## The Training Set Is The Whole Game (I Learned This The Hard Way)

When I first sat down to build this pipeline, I had the same instinct everyone has on day one. Dump a bunch of NL→SQL pairs into a JSONL file. Hit train. Wait an hour. Profit.

Three hours later I had a fine-tuned model that confidently produced SQL referencing tables that didn't exist, wrote joins that made no anatomical sense, and slapped `LIMIT 10` on every single query, because roughly 90% of my training examples ended in `LIMIT 10`. The model did exactly what I trained it to do. That was the problem.

I should have known better. I have been doing data work for over twenty years. I still made the rookie mistake. Sorry, not sorry, but also: yes, sorry.

The real lesson, and the actual point of this whole post, is that the *composition* of your training corpus matters more than its size. It needs to teach the model several different things at the same time, and each of those things wants a different *kind* of example. You can't get there with one source. You build it in layers.

Here is how the layers work in the pipeline I'm currently running.

### Layer A: The Domain Corpus (The Main Course)

This is the workhorse. For a test schema I've been pounding on (a sales-and-CRM database with about 76 tables), the current domain corpus has roughly **9,700 NL→SQL pairs**. That sounds like a lot. The catch is: only about 1,370 of those are unique SQL strings. The rest are paraphrases of questions that map to the same SQL.

How does 1,370 unique queries become 9,700 training examples? Layered construction, like a lasagna:

* **62 hand-seeded pairs** that capture the obvious analyst questions ("show me top customers this month", "what's our open pipeline by region")
* **147 verified production queries** lifted directly out of `pg_stat_statements` on a real database, then run backwards through a model to generate plausible NL questions for each one
* **About 1,100 LLM-synthesized examples**, call it roughly 15 questions per table across 75 tables, every single one validated by actually running it against the schema with a `LIMIT 0` outer wrap so we know it parses and references real columns
* **Around 8,500 synonym-substituted variants** where the SQL stays identical and only the question phrasing changes ("show me revenue", "what's our topline", "how much did we make", "give me the number")

That last layer is the one that surprised me most. The synonym pass, just rephrasing questions while keeping the target SQL fixed, does a disproportionate amount of work. The model is learning that *intent* is what matters, not the exact wording. Same target SQL, ten different ways to ask for it, ten times the gradient signal pointing in the right direction. It's almost embarrassing how cheap and effective this is.

### Layer B: Public Datasets (The Ballast)

If you only train on your domain, the model overfits to your domain and forgets how to handle anything that doesn't look like your test schema. So we mix in pairs from BIRD (a popular NL2SQL benchmark) and a Gretel-synthesized Postgres dataset, all parse-validated against a real Postgres parser before they go into the pile.

Think of this as ballast. It's not what gives the model its specialized knowledge. It's what keeps the boat from tipping over in unfamiliar waters.

### Layer C: The Schema-Agnostic Syntax Corpus (The Secret Sauce)

This is the layer I'm most excited about, and it took the most thought to design. Here's the problem it solves:

Even if you train on thousands of domain examples and thousands of public ones, your model will still have *gaps*. Maybe your domain corpus never happens to include a `LATERAL` join. Maybe it has exactly two `DISTINCT ON` queries. Maybe `jsonb_path_query` simply never comes up in your business questions. So the model never learns those constructs reliably. It will eventually be asked one and produce something that looks vaguely SQL-shaped and is completely wrong.

The fix: a deliberately **schema-agnostic Postgres syntax corpus** built against a tiny synthetic schema (think a generic `orders`, `customers`, `products`, `line_items` setup with about ten columns total). For each of 18 specific Postgres constructs, we generate roughly 30 example NL→SQL pairs, then validate every one against a real connection. The constructs cover what I think of as the "if you don't know these, you can't write idiomatic Postgres" list:

* Common Table Expressions (`WITH ...`)
* Window functions (`OVER (PARTITION BY ...)`)
* `LATERAL` joins
* `DISTINCT ON`
* JSONB extraction and path queries (`->`, `->>`, `jsonb_path_query`)
* `date_trunc` and `extract(epoch from ...)`
* `generate_series`
* `string_agg`, `array_agg`, `unnest`
* Filtered aggregates (`count(*) FILTER (WHERE ...)`)
* `GROUP BY ROLLUP`
* `ILIKE` and case-insensitive regex (`~*`)
* Casting (`::timestamptz`, `::jsonb`)
* `COALESCE` chains
* `CASE WHEN`
* Interval arithmetic (`now() - INTERVAL '7 days'`)
* `UNION`, `INTERSECT`, `EXCEPT`

The result is roughly 540 examples after the parse-validation pass kills the bad ones. And here's the part that genuinely makes me happy: this corpus is **completely reusable**. It's not bound to any particular application schema. You build it once, you commit it as a versioned fixture in your repo, and every future LoRA training run for any schema benefits from it. One afternoon of work, infinite reuse. I don't get a lot of free lunches in this job. This one is on the house.

---

## The Format: ChatML, And Why The Schema Goes In The User Turn

All three layers get reshaped into the same ChatML structure before they're merged. A single training example looks like this:

```json
{
  "messages": [
    {
      "role": "system",
      "content": "You are a PostgreSQL 16 SQL expert. Given a natural language question and a database schema, generate a single valid PostgreSQL SELECT statement..."
    },
    {
      "role": "user",
      "content": "Schema:\n<schema>\nCREATE TABLE app.orders (id int, customer_id int, total numeric, ...);\n</schema>\n\nQuestion: How many orders did we close last week?"
    },
    {
      "role": "assistant",
      "content": "SELECT count(*) FROM app.orders WHERE status = 'closed' AND closed_at >= now() - INTERVAL '7 days';"
    }
  ]
}
```

There are a couple of decisions buried in here that I want to call out, because they're easy to get wrong, and getting them wrong will quietly wreck your training run.

**The schema lives in the user message, not the system prompt.** This is deliberate, and it's the single most important formatting choice in the whole pipeline. At inference time, the schema is the thing that *changes from question to question*. The model's job is to read the schema as input data, parse it on the fly, and generate SQL against it. If you bake one schema into the system prompt during training, you teach the model to memorize that schema instead of learning how to read schemas in general. You will get a model that works great on your test data and falls apart on anything else. Don't do that.

**The schema is a minimal `CREATE TABLE` projection.** Pulled from `information_schema.columns`, just enough to convey table names, column names, and types. No indexes, no constraints, no comments, no FK definitions. Tokens are precious during training. Bloat hurts.

**The syntax corpus uses a slightly enhanced system prompt** that explicitly says "use Postgres-specific syntax and features where appropriate, including CTEs, window functions, JSONB operators, LATERAL joins, DISTINCT ON, and other Postgres extensions." This nudges the model to *reach for* idiomatic Postgres on those examples instead of producing the lowest-common-denominator SQL that would also run on SQLite. We want it to know it's writing for Postgres specifically, not generic ANSI SQL.

---

## Merge, Dedup, Shuffle (The Boring Final Step That Actually Matters)

Once the three layers are reshaped into ChatML, they get merged with a **collision priority**. When two rows have the same NL question (after normalizing: lowercased, whitespace collapsed, MD5'd), the higher-priority source wins and the duplicate is dropped. The order looks like this in code:

```python
SOURCE_PRIORITY = {
    "sales_demo_corpus": 1,   # domain SQL: most valuable
    "public_bird":       2,   # benchmark ballast
    "public_gretel":     3,   # synthesized public pairs
    "syntax_corpus":     4,   # construct filler, yields to anything specific
}

def normalize_nl(nl: str) -> str:
    return re.sub(r"\s+", " ", nl.strip()).lower()

# on collision, lower priority number wins
if new_pri < existing[0]:
    by_hash[h] = (new_pri, line)
```

The reasoning is straightforward. Domain examples are most valuable because they teach your specific schema. Public examples are second because they keep the model honest. The syntax corpus yields to anything more specific because it's there to fill construct gaps, not to compete with real domain SQL.

Then everything gets shuffled with a fixed random seed, because reproducibility matters when you're going to run A/B tests on training corpora. Same input, same shuffle, same training run, every time. (Future-you will thank present-you for this. Present-you should still curse past-you for not doing it sooner.)

The final artifact is one `lora_combined.jsonl` file with a stats dump alongside it. For the current run that's roughly: 8,500 from the domain layer, 3,000 from the public datasets, and 540 from the syntax corpus. After dedup, about 12,000 examples, which fits comfortably in 3 epochs on a single GPU in under an hour.

---

## What Actually Gets Trained (For Completeness)

So you can picture the whole thing: the LoRA adapter targets every linear projection in the attention and MLP blocks of the language model. The actual config is short enough to fit in a tweet:

```python
lora_config = LoraConfig(
    r=16,
    lora_alpha=32,
    target_modules=[
        "q_proj", "k_proj", "v_proj", "o_proj",   # attention
        "gate_proj", "up_proj", "down_proj",      # MLP
    ],
    lora_dropout=0.05,
    bias="none",
    task_type="CAUSAL_LM",
)
```

The base model is loaded in bfloat16 with SDPA attention and gradient checkpointing turned on, and because Qwen3.5-4B is technically a vision-language model, the visual tower is explicitly frozen as a belt-and-suspenders move (we definitely don't want any image gradients leaking in when we're teaching it SQL).

Three epochs. Cosine schedule. LR 2e-4. Batch 4 with grad accumulation of 4 for an effective batch of 16. None of those numbers are the interesting part of the story. The JSONL file is.

---

## What I've Actually Learned Doing This

A few things I either didn't expect or learned the hard way.

First, schema is *input*, not memorization. I cannot say this loudly enough. Put the schema in the user message, vary it across examples, and the model learns to *read* schemas instead of memorizing one. Bake it into the system prompt and you'll get a model that aces your test data and faceplants on everything else.

Second, cheap synonym expansion punches way above its weight. Multiplying NL phrasings against a fixed SQL target is the highest-ROI move in the whole pipeline, and it costs you one afternoon of regex and a thesaurus. Do it.

The rest in bullet form because I'm not a monster:

**The schema-agnostic syntax corpus is a real asset.** I think most teams building NL2SQL fine-tunes are missing this layer. Build it once, commit it forever, reuse it across every future training run regardless of schema. Free quality. I don't know why this isn't standard.

**Dedup and source priority matter more than raw row count.** A 9,700-row corpus that's actually 1,400 unique SQLs with paraphrases will out-train a 50,000-row corpus of low-quality scraped pairs. Coverage of intent beats coverage of strings.

**You will not catch composition bugs in training. You will catch them in eval.** Build the eval harness *before* you start training, not after. (See: my earlier confession about the model that put `LIMIT 10` on everything.)

---

## What's Cooking Next

The LoRA is training as I'm typing this sentence. The interesting question, the one that justifies this whole exercise, is the A/B delta against the base 4B model on a held-out eval set. I'm scoring four things per question: does the SQL parse, does it reference the right tables, does it actually execute against the database, and does it return non-empty results. Base model versus LoRA-merged model, identical questions, identical prompt, identical scoring. No mercy.

Part 4 of this series will have the actual numbers, including which Postgres constructs the LoRA learned cleanly and which ones it still mangles. My current bet (call it a hypothesis, please don't quote me on it before the data is in): big improvement on table selection and join correctness for the domain schema, modest improvement on idiomatic Postgres syntax thanks to layer C, and basically zero improvement on questions that fall outside both. That's what the corpus composition predicts. We'll see if I'm right or if I get to eat a slice of humble pie in front of the entire internet. Either outcome is fine, because the numbers are the point.

If you're building your own NL2SQL fine-tune today and you take exactly one thing from this post, take this: spend 80% of your effort on training set composition, 15% on the eval harness, and 5% on the actual training config. That ratio feels backwards to almost everyone hearing it for the first time. It also happens to be the truth. You'll figure that out one way or another, and I'd rather you figure it out from a blog post than from a wasted week of GPU time.

What questions would *you* throw at a model like this to see if it actually understands your schema? Tell me. I'm collecting evil eval questions and the meaner the better.
