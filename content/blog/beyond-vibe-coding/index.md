---
title: "Vibe Coding Isn't the Problem. Stopping at Vibe Coding Is."
date: 2026-05-17
draft: false
tags: ["ai", "agents", "vibe-coding", "engineering", "llm", "software", "workflow"]
summary: "Vibe coding is a real and useful phase — the problem is people stop there. The space between 'I had an idea on a plane' and 'this runs in an air-gapped Kubernetes cluster' is where the actual work happens. A generalizable playbook for the middle, starting with: treat the LLM like a very literal child."
build:
  list: never
---

"Vibe coding" has become an insult. Say it at a meetup and watch a room full of senior engineers wince. It's the new "script kiddie" — a way to dismiss someone's work without having to look at it.

Here's my problem with that. Vibe coding is a real and useful phase of building software. It's how a lot of working software gets started right now, including most of mine. The issue isn't that people vibe. The issue is that people *stop there.*

You don't ship vibe code to production. You ship what comes after the vibe — a properly architected version that took the prototype's ideas and put real engineering around them. The space between "I had an idea on a plane" and "this runs in an air-gapped Kubernetes cluster for an enterprise customer" is where the actual work happens. Most of the noise about vibe coding completely misses that middle.

Let me walk through how I do it, because I think the playbook is generalizable.

## Treat the LLM like a very literal child

The single most important thing to internalize: an LLM will take you absolutely, painfully literally. It's not stupid. It's not lazy. It's *literal*. Like a five-year-old who you told to "put the toys away" and came back to find them shoved behind the couch.

Real example. Say I'm building a Postgres proxy that intercepts queries and collects telemetry, and I tell the agent: *the overhead has to be under 100 microseconds per query.*

What happens? It will hit 100 microseconds. Absolutely. Promise.

How? Sometimes by writing genuinely good code. Sometimes by dropping the durability guarantees you didn't think to specify. Sometimes by skipping the audit log on certain code paths. Sometimes by losing the full query context because the parser is "too slow." It will technically meet your spec while quietly breaking the things you assumed were sacred — because you didn't say they were sacred.

This is the part you have to plan for. The agent isn't trying to deceive you. It's just optimizing for the contract you actually wrote, not the contract you *meant.* That's on you to fix.

## Write a mission brief, not a ticket

The fix is a real contract up front. I have a skill that builds what I call a mission brief. Some people call it a charter or a constitution. The name doesn't matter, the contents do.

A mission brief locks in:

- The hard requirements (it must do X)
- The performance envelope (under Y latency, fits in Z memory)
- The **non-negotiables** that the agent isn't allowed to trade away (ACID, audit trail, RLS enforcement, whatever your equivalents are)
- The environment constraints (air-gapped, no external calls, on-prem only)
- The reporting contract — what I want documented when the agent makes a tradeoff

That last one is the one most people skip and it's the most important. I want an audit trail of every decision the agent made that wasn't obvious. If it dropped a feature, swapped a library, or decided a corner case wasn't worth handling, I want to know — in writing, at the end of the run. No hidden tradeoffs. If I have to learn about it by reading the code, the agent already failed.

## Use more than one model. Make them argue.

This is the part that I think a lot of people aren't doing yet, and it's a force multiplier.

I don't trust any single model to review its own work. I don't even trust two of them. When a project matters, I run a triangle: Claude builds, Codex reviews, and I have Qwen Coder or another model do a third-party pass on the same code. They will absolutely disagree with each other. That's the point.

Models have different blind spots. Claude is great at architecture and brainstorming but will sometimes wave its hands at performance details. Codex catches a lot of practical implementation bugs but is less opinionated about higher-level design. A local Qwen Coder will surface a totally different set of concerns again. When all three flag the same thing, it's almost certainly real. When only one flags it, I look harder before I act.

The reviewer's job, by the way, is not to fix the problems. I do not want Claude to read Codex's code and then start "fixing" it. That's how you get into a doom loop where two agents make a worse mess. The reviewer's job is to *find* problems — not solve them. I decide what to fix and either I do it or I direct a build agent to do it under a fresh, narrow brief.

## Skills, not vibes, do the heavy lifting

Most of the work I've put into agentic coding the last six months isn't building agents. It's building skills.

Skills are the codified version of "what does good look like at my shop." Each one is a repeatable, runnable check that I can throw at any project. The ones I use constantly:

- **A-hole architect** — the brutal review. It complains about everything. Most of what it complains about is actually right. The rest is useful signal.
- **Production readiness** — checks against a real production checklist. Logging, monitoring, config management, secrets handling, failure modes, retries, idempotency. Catches stuff I forgot to think about.
- **User testing** — simulates real user paths. Finds the dumb usability holes that a developer would never trip on but a real user would hit in 30 seconds.
- **UX audit and browser test** — for anything with a UI. Different lens than the user test; catches different things.
- **Reverse engineer + tech regret** — for when I want to break down an existing prototype and figure out what to keep and what to rebuild (more on these in the next post).

Once these exist, they run on every project. They're not optional. They're not "if I have time." They're the boring 20% that used to kill momentum, and now they run in the background while I think about the next thing.

If you take one thing from this post: **the lift from vibe to architected isn't a different mindset, it's a different toolbelt.** Build the toolbelt once and you can vibe everything else.

## Where this falls apart

I want to be honest about where this approach breaks down, because too much of the AI-coding discourse is just people posting wins.

**Side projects vs enterprise software is a real line.** Vibing a personal tool that lives in your home directory is different from shipping software an enterprise customer is going to run in production for five years. The further toward "enterprise" you go, the more the spec-and-rebuild step matters, and the less room there is for cleverness. Security, compliance, integration with third-party systems, long-term maintainability, the ability to onboard a human engineer six months from now — these are project-killers if you ignored them in the vibe phase.

**Some problems don't vibe well.** Anything where correctness is non-obvious and edge cases are the whole point — distributed systems consensus, financial settlement, anything safety-critical — is a bad fit for the "start by vibing it" approach. For these, start with the spec, not the prototype. Or start with the prototype but be ready to throw 100% of it away.

**The reviewer skill matters more than the builder skill.** If you can't tell when an agent gave you a bad answer, none of this works. You can't bootstrap taste from nothing. The folks who succeed at this style of work are the ones who already had the engineering chops to know what good looks like — they're just not typing it anymore.

## So what

If you've been writing off vibe coding as not-real-engineering, I get it. A lot of what gets posted under that flag is not real engineering. It's a working demo plus a Twitter thread.

But the demo is the on-ramp, not the destination. The actual playbook is: vibe to find the shape of the idea, then spec the real thing, then have the agents rebuild it under proper constraints, with multiple reviewers, with skills doing the boring work, with an audit trail of every tradeoff.

That's not vibe coding. That's a small senior engineering team running at three times the speed they used to. And the people who are doing this quietly are going to start shipping software that the rest of the industry can't keep up with.

Next post: the part I glossed over — how to take that ugly first prototype and turn it into something you'd actually be proud to ship.
