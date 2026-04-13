---
title: "Your LLM Doesn't Know What 'Revenue' Means. Here's How to Fix That."
date: 2026-04-05
draft: false
tags: ["nl2sql", "postgres", "ai", "llm", "semantic-layer", "pg_agents"]
summary: "A step-by-step walkthrough of building a PostgreSQL semantic layer in pg_agents — crawl the schema, enrich it, define your vocabulary, lock down categoricals, and promote the queries that work."
---

*Part 2 of a series — [Part 1 covered why LLMs fail at SQL in the first place](../why-llms-fail-at-nl2sql/).*

I had a customer last year — mid-size SaaS company, solid engineering team, about 30 tables in their main operational schema. They hooked up an AI SQL assistant, let it loose, and it immediately answered "what's our revenue this month?" with a number that was about 40% too high. Turns out the model was summing `total_amount` from orders without filtering out cancellations. Totally valid SQL. Completely wrong answer.

They blamed the LLM. The LLM wasn't the problem.

The problem was that nobody had ever told the system what "revenue" actually means in their context. That's not an LLM failure — that's a missing semantic layer. And it's fixable. In this post I'm going to walk you through exactly how to build one in pg_agents, step by step, without sugarcoating the parts that still need human attention.

---

## Step 1: Crawl Your Schema (No, Really — All of It)

This sounds obvious but I still see people skip it. Everything downstream depends on the crawl. The catalog tables (`catalog_schema`, `catalog_column`) are what the resolver actually looks at when it's figuring out which tables and columns to use. Without them, you're asking the model to guess from nothing.

Hit `POST /api/catalog/crawl/{connection_name}` or just click the **Crawl** button next to your connection in Studio. Either way, same result: pg_agents reads your schema and populates the catalog foundation.

One thing I keep having to remind people: crawl all your connections, not just the obvious one. If you've got a `localDB` self-connection pointing back at your own schema, crawl that too. If you've got a read replica for analytics, crawl it separately. The resolver is connection-scoped, which means the semantic layer you build is going to be tied to the connection name you crawl against. Get that foundation right from the start.

---

## Step 2: Let the Enricher Do the Tedious Parts

Once you've got raw schema metadata, fire off `POST /api/catalog/enrich-all` and let background parallel workers run the catalog enricher agent across every table and column.

What does "enrich" mean here? The agent reads each table's name, columns, and data patterns, then infers business names, entity types, and metrics — stuff like recognizing that a table called `ord_hdr` is actually an Order Header and that `cust_id` is a foreign key to a customer entity. It saves all of that back to the catalog.

You can watch it run via `GET /api/jobs`. It'll show you per-worker progress, which is useful when you have a 600-table schema and you're wondering if it's hung or just chugging along.

This step handles roughly 80% of the work automatically. The LLM is pretty good at inferring business meaning from naming conventions, column types, and relationships it can see in the schema. It's not perfect — and I'll get to that — but starting here saves you hours of manual annotation.

---

## The Enricher Gets Most Things Right. Some Things, Not.

The enricher will occasionally make something up. I don't mean hallucinate wildly — I mean it'll give a table a business name that's technically plausible but wrong for your specific domain. A table called `ev_log` might get labeled "Event Log" when your team calls it the "Audit Trail." Small difference, but it matters when someone asks "show me the audit trail for user 123."

The Studio catalog view lets you inline-edit business names and descriptions directly on the table and column rows — no SQL required. Do a spot-check pass after enrichment. It takes maybe 20-30 minutes on a typical schema and it's worth every minute.

Pay special attention to the column profile page. The enricher infers roles for each column: key, date, measure, flag, dimension, text, identifier. These roles affect how the resolver weights columns when assembling query context. A column inferred as a `measure` gets treated as an aggregation candidate; a `key` gets treated as a join anchor. Check the ones that look off.

Also — and this one actually matters — look at the **Ambiguity Detection** tab. It'll flag columns like `flg_1` (opaque name, nobody knows what this is), `amount1`/`amount2` (numeric suffixes that confuse join path resolution), and cases where the same column name appears in multiple tables with different data types. These are your model's blindspots. Fix the easy ones in the catalog, document the ones you can't change in the schema itself.

---

## Step 4: Define Your Vocabulary

This is also the step most teams skip, because it's manual and it feels like it shouldn't matter as much as it does. It does. Do it anyway.

Synonyms in pg_agents are the bridge between how your users talk and what's actually in the database. "Revenue" might mean `SUM(total_amount) WHERE status != 'cancelled'` in your world. "Active customer" might mean a customer who's placed an order in the last 90 days. "Churn rate" might be a specific formula involving two different tables. None of that is inferable from column names alone.

You teach this to the system through synonym entries — either via the Synonyms tab in Studio or directly in the `query_concept_synonym` table. Map your top 10-20 most-queried business terms to their actual SQL expressions or table/column references.

In the SaaS company example from the intro, the fix was a single synonym entry: `revenue` → `SUM(o.total_amount) WHERE o.status NOT IN ('cancelled', 'refunded')`. That's it. One entry, the wrong-answer problem went away.

Do your highest-traffic concepts first. If "MRR," "churn," and "DAU" appear in half your queries, start there. Don't burn time on the obscure stuff until the common terms are locked down.

---

## Step 5: Define Relationships (the Visual Designer Is Worth Using)

The crawl infers foreign key relationships from your schema constraints. If you've got proper FKs defined, that's great — the crawler gets most of it right. But if you're working with a schema that has implicit relationships (and most real-world schemas do, because someone decided constraints were "too slow" in 2014), you'll need to fill those in.

The Visual Relationship Designer in Studio lets you drag columns between tables to define joins, set the relationship verb (`placed_by`, `assigned_to`, `belongs_to`), and mark cardinality. These verbs aren't decorative — the NL resolver uses them when it's constructing join paths from a natural language question. "Show me orders placed by VIP customers" works a lot better when the system knows that `orders.customer_id` is `placed_by` a `customers` row.

There's also an NL interface for this: type something like "orders are placed by customers using orders.customer_id = customers.id" and the system will extract the join proposal and ask you to confirm. I use that for quick additions when I'm already in a chat session and don't want to navigate to the relationship designer.

---

## The Two-Second Investment Most Teams Skip

This one compounds over time and it's easy to forget to do it.

When you run a query in Studio and it's correct — the SQL is right, the results make sense — click the thumbs-up button on the message. That saves the question-to-SQL mapping to `query_semantic_kb` with real ONNX embeddings generated locally. No API call, no latency hit.

Next time someone asks a semantically similar question, the resolver finds the proven pattern in the KB and uses it as a high-confidence starting point. After a few weeks of normal usage on a real schema, your KB accumulates a library of working SQL for your specific data. The model stops reinventing the wheel on common queries and the accuracy on those patterns goes to near-100%.

I've seen teams get lazy about this and then wonder why accuracy plateaued at 70%. Promote your good queries. It takes two seconds.

---

## Step 7: Lock Down Your Categorical Columns

If `order_status` in your database can only ever be `'pending'`, `'processing'`, `'shipped'`, `'delivered'`, or `'cancelled'` — the model needs to know that. Otherwise it might generate `WHERE order_status = 'active'` or `WHERE order_status = 'open'`, which is reasonable English but wrong SQL that returns zero rows.

Taxonomies in pg_agents are how you define the valid values for categorical columns. Studio has a Taxonomies section per connection. This is especially critical for any column that looks like a status field, a type enum, or a category flag. Boolean-ish columns with string values (`'Y'/'N'`, `'yes'/'no'`, `'true'/'false'`) are particularly sneaky — define them.

It's not glamorous work. Set aside an hour, go through your most frequently filtered columns, and enter the valid values. The accuracy improvement on filtering queries is immediately measurable.

---

## The Compound Effect in Practice

Each layer here adds to the previous one, and the improvement isn't linear — it stacks. Synonyms alone can take a schema from 50% accuracy on business queries to 75%. Add proper relationships and you pick up another 10-15 points on multi-table joins. Add a few weeks of promoted queries and you're looking at 86-95% on your most common question patterns.

That's not a theoretical number. That's what we've measured on real schemas with real data. The work to get there on a mid-complexity schema (30-50 tables, clear domain model) is about 3-4 hours of focused setup. Most of that time is in steps 4 and 7 — the vocabulary and taxonomy work that only a domain expert can do.

The other thing worth saying: the system gets smarter over time without you doing anything. Every promoted query enriches the KB. Every correction you make to a business name updates what the resolver uses. It's not fire-and-forget, but the maintenance burden after initial setup is low.

---

## What Not to Do

Skip the crawl and try to manually enter table metadata from scratch. I've watched someone do this with a 90-table schema. Three days later they had about 20 tables entered and were exhausted. Just run the crawl.

Enrich without then spot-checking. The LLM gets most things right and confidently gets a few things wrong. A business name it invented for a poorly-named table will propagate through your synonym and relationship definitions if you don't catch it early.

Start with your obscure terminology instead of your top-10 most-queried concepts. I had a customer spend an afternoon defining synonyms for their internal reporting codes that nobody outside finance ever queried. Meanwhile "active users" and "retention rate" — which showed up in every executive dashboard — were returning garbage. Do the high-traffic terms first.

---

## What's Next

[Part 3 of this series](../training-sets-for-lora-nl2sql/) goes deeper on the embedding layer — specifically, what happens when you want to customize the semantic matching with your own domain embeddings instead of relying on the general-purpose model. We'll look at the ONNX embedding pipeline and where LoRA fine-tuning fits in for teams that have enough query history to train on. That's where the accuracy ceiling really starts to push past 95% on complex schemas.

In the meantime: run the crawl, kick off the enricher, and spend an hour on your top 10 synonyms. That's all it takes to go from "the AI makes up SQL" to "the AI mostly gets it right." The rest is polish.
