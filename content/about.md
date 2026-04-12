---
title: "About"
description: "Who's behind Yonk-Labs, and why it exists."
showDate: false
showReadingTime: false
showAuthor: false
---

Hi. I'm Matt Yonkovit. Most people who've been around open source databases for a while know me as The Yonk. Or The HOSS, if you want the full absurd title: Head of Open Source Strategy. I picked that one myself. I regret nothing.

This is where I park the stuff I build on nights and weekends. Some of it is useful. Some of it is me arguing with myself in code. Occasionally those are the same thing.

## The 20-second career summary

I've been doing databases and open source for over 20 years. Started as a DBA and sysadmin back when "cloud" meant something you checked the weather for. Worked at MySQL AB, Sun Microsystems, and then spent nine-plus years at Percona wearing a lot of hats — DBA, consultant, customer success, Chief Customer Officer, Chief Experience Officer, Head of Community. After Percona, I did open source strategy at Scarf, spent time at JetBrains, Mattermost, and StreamNative, and these days I'm at EDB working on the intersection of AI and PostgreSQL.

I've run P&Ls, built DevRel teams, managed customer success orgs, and sat in enough boardrooms to know what not to say in them. I'm an open source true believer *and* the guy who has had to sign the paychecks. People think those are in tension. They're not. When community and business stop talking to each other is when projects die, and I have watched that movie more times than I would like.

## What I actually care about

Here's what I'll rant about if you buy me a beer at a conference:

**Data engineering is the hard part of AI.** Not the model. Not the prompt. The pipeline. The chunking. The embedding strategy. The filtering on retrieval. I've been benchmarking this stuff for months and I have thoughts — most of them are going to make a few vendors uncomfortable. Sorry, not sorry.

**Right-sized AI is a thing.** Not everything needs a 400-billion-parameter model. A lot of "AI problems" are solved better by a purpose-built model under 10B parameters running locally, plus a database that actually knows what it's doing. PostgreSQL + pgvector + a small embedding model will eat 80% of the use cases people are paying OpenAI rates for. I'll die on this hill.

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
