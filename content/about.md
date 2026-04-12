---
title: "About"
description: "Who's behind Yonk-Labs, and why it exists."
showDate: false
showReadingTime: false
showAuthor: false
---

Hi. I'm Matt Yonkovit. Most people who've been around open source databases for a while know me as The Yonk. Or The HOSS, from the years I carried around the title Head of Open Source Strategy. I picked that one myself. I regret nothing.

This is where I park the stuff I build on nights and weekends — and increasingly, the stuff I build during the day that refuses to stay in a single company repo. Some of it is useful. Some of it is me arguing with myself in code. Occasionally those are the same thing.

## What I'm actually into

I like databases. Specifically, I like what happens inside them when nobody's watching — buffer pools doing clever things, query planners making bad decisions, replication quietly falling over at 2am. I've spent 20+ years chasing that stuff, and somewhere along the way I ended up on the AI side of the fence too. Not because AI is shiny. Because the *data* problems behind AI — chunking, embeddings, hybrid retrieval, air-gapped inference on locked-down hardware — turned out to be the exact same flavor of problem I've been working on my whole career. Just with more GPUs and a fresh coat of hype.

Right now I'm at **EnterpriseDB**, where I get paid to think about how PostgreSQL and AI should meet. In practice, that means a lot of Kubernetes-native operations, a lot of time on NVIDIA DGX hardware, a lot of debugging weird inference bugs, and a lot of arguing about governance. Agentic AI with JWT-scoped purpose controls and Postgres RLS as a hard policy layer. Right-sized models that don't require you to ship your data off-prem. Inference pipelines in Rust. That kind of thing.

Before that, I spent a year or so running open source strategy at **Scarf**, helping maintainers actually see who was using their packages. Before that, I was at **Percona** for the better part of a decade, in roles that kept shape-shifting — Principal Architect, VP of Global Services, Chief Experience Officer, and eventually the HOSS. While I was there I worked extensively on setting the groundwork for Percona's PMM and QAN observability tools, helped launch the Percona PostgreSQL and MongoDB Server product lines, built out customer success and delivery orgs, and generally spent a lot of time trying to get the engineering side and the business side to talk to each other. And before *that* I was contracting into MySQL AB / Sun Microsystems on InnoDB internals, which is where I learned that database performance is 10% clever algorithms and 90% "what is this one pathological query actually doing to the buffer pool."

I've run P&Ls, built DevRel teams, sat in enough boardrooms to know what not to say in them, and shipped a lot of open source. I'm a true believer *and* the guy who has had to sign the paychecks. People think those are in tension. They're not. When community and business stop talking to each other is when projects die, and I have watched that movie more times than I would like.

I also founded the **[Open Source Business Community](https://opensourcebusiness.community)** — a public resource for metrics, guides, and podcasts about how to run an open source company without setting it on fire.

## The podcasts and the videos

Two shows you might know me from:

- **[Percona's HOSS Talks FOSS](https://percona.podbean.com/)** — the show where I sit down with developers, DBAs, CEOs, and community maintainers from all over the open source database world. MySQL, PostgreSQL, MongoDB, MariaDB, Cassandra, the whole menagerie. Guests have come from DataStax, Google, AWS, and basically every database company you can name. Video on YouTube, audio everywhere podcasts live.
- **[The Hacking Open Source Business Podcast](https://podcast.hosbp.com/)** — co-hosted with Avi Press of Scarf. This one is less about the code and more about the *business* of open source. Licensing drama, VC incentives, commercialization strategies, what actually works, what quietly doesn't. If you run or work at an open source company and you've ever wondered why the numbers don't add up, this show is for you.

I've also done a lot of conference talks over the years — FOSDEM (usually on data engineering and RAG accuracy these days), PGConf, FOSSY, Open Source Summit, All Things Open, and obviously Percona Live. If you've sat through one of my sessions, I apologize and I hope the jokes landed.

What I'll be putting in the [videos](/videos/) and [podcasts](/podcasts/) sections of this site is a little different. More personal. Experiments, demos, unfiltered rants, and the kind of stuff that doesn't fit cleanly into a corporate feed. Think of it as the directors-cut-with-commentary version of whatever I'm obsessing over that week.

## What I'll rant about if you buy me a beer

**Data engineering is the hard part of AI.** Not the model. Not the prompt. The pipeline. The chunking. The embedding strategy. The filtering on retrieval. I've been benchmarking this stuff for months and presenting the results on conference stages, and I have thoughts — most of them are going to make a few vendors uncomfortable. Sorry, not sorry.

**Right-sized AI is a thing.** Not everything needs a 400-billion-parameter model. A lot of "AI problems" are solved better by a purpose-built model under 10B parameters running locally, plus a database that actually knows what it's doing. PostgreSQL + pgvector + a small embedding model will eat 80% of the use cases people are paying OpenAI rates for. I'll die on this hill.

**Air-gapped AI is real and it's coming for you.** Regulated enterprises, government, healthcare — they're going to run LLM inference on-prem or nowhere, and the tooling for that is *not* where it needs to be yet. Half of my current work is fixing that.

**Open source communities need business models, and business models need communities.** The companies that forget this — on either side — become cautionary tales. I've watched it happen at places you've heard of, and it's always the same pattern.

**Honest benchmarks over marketing benchmarks.** If your graph starts at 80% of the Y-axis to make a 2% improvement look like a victory, I am *already* mad at you.

**Database design is a lost art.** There, I said it.

## The projects here

Everything in the [projects](/projects/) section is something I actually use or have used. A few highlights:

- **[pg-retest](/projects/pg-retest/)** — Oracle RAT, but for PostgreSQL, in Rust, with a demo you can spin up in one command. Capture production traffic, replay it against a new target, know before you cut over.
- **[llm-top](/projects/llm-top/)** — `top` but for LLM inference servers on NVIDIA DGX Spark. Because I got tired of opening four terminals to watch one GPU.
- **[RoboMonkey MCP](/projects/yonk-robo-codemonkey/)** — A local-first MCP server that indexes code and docs into Postgres with pgvector so coding agents stop losing the plot on long sessions. Yes, it is 100% unapologetically vibe-coded. That's the origin story and I'm keeping it.
- **[os-db-json-tester](/projects/os-db-json-tester/)** — Benchmark harness for JSON workloads across MySQL, PostgreSQL, and MongoDB. Exists because every vendor's JSON benchmarks are, how do I put this politely, *optimistic*.

## Things that are not in my job description but I do anyway

Outside the database world, I build simulation games nobody asked for. A 44K-line wrestling booking simulator with feud heat tracking and tag team chemistry decay. A 53K-line meta-tool for building management sims. A multi-agent system for writing novels. I cook for my teams, sometimes over video calls, which is weirder than it sounds. I'm a genuine wrestling nerd (the real kind — I will absolutely argue the business of kayfabe with you).

None of this is strategy. It's just what happens when you let a curious person have too much unstructured time and a working laptop.

## Why this site exists

Three reasons, because I list things in threes:

1. I build a lot of stuff and needed somewhere to put it that wasn't twelve abandoned repos and a LinkedIn post.
2. The blog, videos, and podcast sections are for the long-form rants. I'd rather write these down than lose the argument to whoever yelled back at me on Twitter.
3. It's an excuse to dogfood my own "small static site, big ideas" belief. No JavaScript framework du jour. No analytics trying to follow you around. Just markdown, Hugo, and GitHub Pages.

If you want to argue, build something together, or just tell me I'm wrong about MongoDB, find me on [GitHub](https://github.com/yonk-labs) or at any database conference where there's good coffee and someone willing to listen.

Welcome to Yonk-Labs. Pull up a chair.
