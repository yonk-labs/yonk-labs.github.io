---
title: "Why LLMs Alone Fail at NL2SQL (And What Actually Fixes It)"
date: 2026-04-03
draft: false
tags: ["nl2sql", "postgres", "ai", "llm", "semantic-layer", "pg_agents"]
summary: "Raw LLMs hit 10-20% accuracy on real enterprise schemas with cryptic column names and tribal-knowledge joins. Here's why, and the semantic-layer fix that takes you from toy to production."
---

*Part 1 of a series on making AI actually useful against real databases.*

I've been a database person for over 20 years. I've seen a lot of things get hyped as "the thing that will change how we interact with data." Natural language interfaces, in particular, have been the zombie idea of the database world — they keep coming back, getting shot down by reality, and then rising again with a new coat of paint.

This time, the coat of paint is "just use an LLM." And honestly? It's not wrong. LLMs are dramatically better at understanding intent than anything that came before them. But "dramatically better at understanding intent" and "actually accurate against your production database" are two very different things.

Here's what the numbers actually look like: on real enterprise schemas — the kind with 15-year-old tables, cryptic column names, and joins that require tribal knowledge — LLMs achieve somewhere between 10% and 20% accuracy out of the box. That's not a typo. We're talking about the state-of-the-art language models, given your schema, and they're getting the SQL right roughly one time in five to ten. On benchmarks with clean, well-documented schemas like BIRD, the numbers look better, but your database isn't a benchmark. It's a crime scene.

---

## The Schema Is the Problem

Let me paint you a picture. You work at a company that's been around since 2009. Your main transactions table has a column called `amt_usd_net_adj`. Another one called `flg_1`. Your customers table has `cust_acct_nbr`. There's a `flg_active` column on the accounts table. Your orders join to customers via `customer_ref_id`, not `cust_id`, because the person who built the schema left in 2014 and nobody wanted to break the stored procedures.

That's not a pathological example. That's Tuesday. I've seen this pattern — or worse — at every company I've worked with, across hundreds of database audits and customer engagements. The human who built this schema knew exactly what every column meant. Their mental model was the documentation. When they left, that documentation went with them.

An LLM doesn't know that "revenue" means `SUM(o.total_amount) WHERE o.status != 'cancelled'`. It might assume `revenue` maps to a column called `revenue`, or maybe `total_amount`, or maybe it guesses `amt_usd_net_adj` because that sounds financial. Any of those guesses produces a query that runs without error and returns numbers that look plausible. That's actually the worst outcome — wrong data that doesn't blow up.

The model doesn't know `flg_active = 'Y'` means the account is live. It might filter on `status = 'active'` — a value that doesn't exist in your status column, which uses `'LIVE'` and `'INACTIVE'` because of course it does. It doesn't know that "top customers" means `customer_tier = 'enterprise'`, not just `ORDER BY revenue DESC LIMIT 10`. It doesn't know that the `orders` table has a soft-delete column that absolutely must be included in every query or you'll surface records from 2011 that someone was supposed to clean up.

---

## "Just Write a Better Prompt" Doesn't Scale

Look, the obvious move is to just put it all in the system prompt. Document your schema, your business rules, your join patterns. Feed it to the model.

Two problems with that.

First, the math doesn't work. A real enterprise schema — I'm talking 477 tables, which is what one of our recent production test customers was running — doesn't fit in a prompt. Even if you could fit the schema definition, you can't fit the semantic meaning: 15 years of "here's what this column actually means" knowledge. There's no token budget for tribal knowledge.

Second, even when it does fit, models forget. Or they hallucinate anyway. I've watched a well-prompted model confidently produce SQL with the wrong join condition, even after explicitly listing the correct join column in the context. The model read it, acknowledged it, and then used a different column. At some point "better prompt engineering" runs into a wall, and that wall is the fundamental limitation of trying to solve a data problem with a text problem.

---

## The Fix: A Semantic Layer Between the Question and the SQL

What actually works is building a translation layer — a semantic layer — that sits between the natural language question and the moment the LLM starts generating SQL. The LLM's job isn't to know your database. The semantic layer's job is to tell the LLM what it needs to know, just in time, for this specific question.

**Synonyms.** A mapping from business terms to actual database formulas. "Revenue" → `SUM(o.total_amount) WHERE o.status != 'cancelled'`. "Churn" → a specific 90-day cohort calculation. This gets assembled into the LLM's context before it generates SQL, so the model isn't guessing — it's been told.

**Entity resolution.** When someone asks about "customers," the semantic layer figures out which of your three customer-adjacent tables they actually mean (`accounts`, `customer_dim`, `cust_master`) and hands the LLM the right one. It uses scoring: table descriptions, column names, access patterns, relationships. The LLM gets "use this table" instead of "here are all your tables, good luck."

**Relationship mapping.** The fact that orders join to customers via `customer_ref_id`, not `cust_id`, lives in the semantic layer, not in the LLM's imagination. When the query needs that join, it gets the correct path.

**Taxonomies.** "Active orders" means `status IN ('processing', 'shipped')`. Not `status = 'active'` — that row doesn't exist. The taxonomy table maps business concepts to actual categorical values in your database, and that gets injected before generation.

**Proven queries.** This one is underrated. If your system has run this question before — or something semantically similar — you can retrieve the SQL that actually worked and give it to the model as a reference. Semantic similarity search (real embedding search, not keyword matching) finds the closest match from a library of verified patterns. The model is now working from a proven template, not improvising.

**Column profiles.** So the model knows `flg_active` is a boolean flag, not a dimension. `amt_usd_net_adj` is a financial measure. `cust_acct_nbr` is an identifier, not something to aggregate. This context changes how the model treats each column in generation.

---

## Before and After

Question: "Show me revenue by top customers this month."

**What an LLM alone might generate:**

```sql
SELECT c.customer_name, SUM(o.total_amount) AS revenue
FROM orders o
JOIN customers c ON o.cust_id = c.id
WHERE EXTRACT(MONTH FROM o.order_date) = EXTRACT(MONTH FROM CURRENT_DATE)
  AND EXTRACT(YEAR FROM o.order_date) = EXTRACT(YEAR FROM CURRENT_DATE)
GROUP BY c.customer_name
ORDER BY revenue DESC
LIMIT 10;
```

Wrong join column (`cust_id` should be `customer_ref_id`). Missing the cancellation filter — so cancelled orders inflate your revenue numbers. No enterprise tier filter, so you're ranking everyone, not "top customers" in the business sense. This query runs. It returns data. It's wrong in three different ways.

**What a semantic-layer-assisted query looks like:**

```sql
SELECT a.account_name, SUM(o.total_amount) AS revenue
FROM orders o
JOIN accounts a ON o.customer_ref_id = a.account_id
WHERE o.status != 'cancelled'
  AND o.flg_deleted = 'N'
  AND a.flg_active = 'Y'
  AND a.customer_tier = 'enterprise'
  AND o.order_date >= DATE_TRUNC('month', CURRENT_DATE)
  AND o.order_date < DATE_TRUNC('month', CURRENT_DATE) + INTERVAL '1 month'
GROUP BY a.account_name
ORDER BY revenue DESC
LIMIT 10;
```

Correct join column. Cancellation filter applied (from the "revenue" synonym). Soft-delete filter applied (from column profiling). Enterprise tier filter applied (from the "top customers" entity definition). Date filter using proper month boundaries.

Same question. Completely different SQL. The second one is what a senior analyst who's been at your company for five years would write.

---

## The Accuracy Jump Is Real

When you wire all of this up properly, the numbers move. A lot. Against the BIRD benchmark — which is the current standard for NL2SQL evaluation — a raw LLM sits in the low-to-mid range. Add a full semantic layer with synonym resolution, entity matching, taxonomy injection, proven query retrieval, and column profiling, and accuracy jumps into the 86-95% range on real queries.

That's not a marginal improvement. That's the difference between a toy and something you can actually use in production.

---

## So Where Does That Leave You?

If you're evaluating LLMs for NL2SQL and you're testing against a clean demo schema with friendly column names, stop. You're not testing the right thing. Test it against your actual database, with your actual column names, with your actual business definitions. That's where you'll find out what you actually have.

The LLM is not the problem. The LLM is capable. What's missing is the scaffolding around it — the system that translates your messy, tribal-knowledge-encoded, historically-accumulated database reality into something the model can reason about correctly.

Next up in this series: [how to actually build that semantic layer in PostgreSQL](../building-your-semantic-layer/) — crawling your schema, profiling your columns, and seeding your synonym dictionary without wanting to throw your laptop into a lake. (It's more manageable than it sounds. Mostly.)
