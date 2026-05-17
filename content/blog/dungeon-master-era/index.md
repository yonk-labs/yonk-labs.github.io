---
title: "The Dungeon Master Era: Why Product and Engineering Are Becoming the Same Job"
date: 2026-05-16
draft: false
tags: ["ai", "agents", "product", "engineering", "career", "llm", "workflow"]
summary: "Agents got good, code became the cheapest thing in the room, and the gap between product and engineering is closing fast. The people who internalize that — who spend their time deciding what should exist and ripping into what the agents hand back — are going to run circles around everyone else."
build:
  list: never
---

If you've followed my LinkedIn or my blog the last couple of months, you've probably noticed I've been dropping a *lot* of stuff. Projects, write-ups, half-baked ideas turning into working software inside a weekend. There's a reason for that, and it's not that I started drinking better coffee.

The reason is the agents finally got good.

I can go from three or four ideas on a Friday night to working software by Sunday — tested across multiple platforms, run against multiple LLMs, validated with real or simulated workload. That used to take months. Sometimes years. Now I'm sitting on a dozen browser tabs, each one running a different agent on a different project, and most of the work I'm doing isn't typing code. It's deciding what should exist, telling the agents what the box looks like, and then ripping into what they hand back.

Which brings me to the thing I actually want to talk about: **the gap between product and engineering is closing, and the people who figure that out first are going to run circles around everyone else.**

## Code is the cheapest thing in the room now

Here's the part that's hard to internalize if you came up writing code by hand: the code is the smallest unit of work now. It is the *least* bottleneck thing in the pipeline.

You will spend way more time on:

- Figuring out what should actually exist
- Hunting edge cases
- Verifying the agent didn't quietly cut corners
- Making the thing survive past the demo

The actual generation of the code? That's the cheap part. Which means the skill that matters isn't "can you write a binary tree from scratch" — it's "can you describe what you want clearly enough that someone (or something) else can build it, and can you tell when they got it wrong?"

That's not a developer skill. That's not a PM skill either. It's the thing in the middle that nobody had a clean name for. I've been calling it the *dungeon master* role, because that's basically what it is: you don't roll the dice, you don't move the pieces, but you decide what the game looks like and you call out when something breaks the rules.

## The 80/20 flip

Anyone who's shipped software knows the joke: the first 80% of a project is a blast. You're building, things are working, the demo looks great. The last 20% — the production hardening, the edge cases, the monitoring, the docs, the security review — takes longer than the first 80%. Sometimes way longer. That's where most side projects go to die and where most enterprise launches slip six months.

Agents flip that.

The fun part is still fun, but now the boring 20% gets handled by skills, pipelines, and review agents that don't get bored. I have a skill that runs a production-readiness audit. One that runs an A-hole architect review (it complains about everything, like that guy at work — you know the one). One that does UX testing, one that does browser testing, one that simulates user paths. I can throw any of these at a project and get back a real list of things that are going to bite me before I ship.

That's the part of the job most engineers actively hate. Now I can offload it to something that does it better than I would, faster than I would, and won't get cranky at 11pm. The 20% just got cheap too.

## What smaller teams look like

The hype cycle right now says you're going to replace 90% of your workforce with agents. That's nonsense. But what's *actually* happening is more interesting: small pods of senior people are going to do the work of teams that used to be ten times the size.

Three or four good people, working in parallel across multiple agentic workflows, can ship more in a quarter than a 30-person org used to ship in a year. The people in those pods aren't junior. They're the ones with enough scar tissue to know what good looks like, enough taste to spot a bad answer, and enough range to wear the product hat *and* the engineering hat in the same afternoon.

If you're a senior engineer who hates meetings and just wants to build — this is the era for you. If you're a product person who has always wished you could just *make the thing* instead of arguing about it in JIRA — also for you. The hard part is the people in between, who built careers on coordinating handoffs between two functions that are about to merge.

## The product person of the future

Here's what I think the job actually looks like in 12 months, on the product side:

You have an idea. You spend a few days researching the space — but the research itself runs as an agent task. You come back to a real write-up. You vibe a prototype over a weekend. You get it in front of three or four trusted people. You either kill it or you keep going. Then you flip hats — you stop being a product person and you become an architect. You take what you built, you break it down, you spec the rebuild, and you let the agents put it back together with the guardrails on this time.

That's not five people across two months. That's one person across three weeks.

And on the engineering side, the mirror image: you stop writing CRUD endpoints and start being the senior reviewer of an agent that writes them for you. You build the skills library that enforces your team's standards. You curate the test harness. You design the system, you don't type the system.

The job didn't go away. It got upgraded.

## So what now

If you're a developer reading this and you still don't have a personal skills library, build one. Pick five things you do over and over — code review, test scaffolding, perf checks, doc generation, security sniff tests — and codify them. That's your new toolbelt.

If you're a PM, stop writing requirements documents like it's 2015. Learn how to write a mission brief that an agent can actually execute against. Learn what a good spec looks like at the level an LLM needs. Run the prototype yourself.

If you manage either of those people, stop staffing teams the old way. The right ratio of senior to junior, the right size of pod, the right boundary between product and eng — all of that is about to look different. Don't fight it. The people who figure out the new shape first are going to eat very well.

I'm calling this the dungeon master era. The dice keep rolling. The question is whether you're the one calling the encounter.
