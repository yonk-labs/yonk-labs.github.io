---
title: "The Ugly Baby Method: Vibe, Reverse Engineer, Rebuild"
date: 2026-05-18
draft: false
tags: ["ai", "agents", "vibe-coding", "engineering", "reverse-engineering", "rebuild", "software"]
summary: "Every project I've shipped in the last six months has been an ugly baby at some point — dead code, 11pm ideas that look stupid at 8am, three abstractions doing the same thing. That's not failure, it's the artifact you need. Put the ugly baby in a glass case, learn from it, then rebuild from zero."
build:
  list: never
---

Every project I've shipped in the last six months has been an ugly baby at some point.

That's not a metaphor I picked because it sounds funny. (Okay, partially.) The first version of anything I build right now is structurally a mess. Half the code is dead. Features that were good ideas at 11pm look stupid at 8am. There are three different abstractions all doing 80% of the same thing. The whole thing technically works, but if you opened the hood you'd cry.

And here's the part that took me a while to learn: **that's exactly what it's supposed to look like.**

The ugly baby isn't a failure. It's the artifact you need to figure out what you should *actually* build. The mistake everyone makes is trying to clean it up in place. You can't. You have to put the ugly baby in a glass case, look at it, learn from it, and then start over from zero with what you learned.

## A real example: lede

Let me walk through one of mine.

[lede](https://github.com/yonk-labs/lede) is my extractive summarization project. The origin story is dumb. I was working with LLMs on a bunch of stuff, and every workflow that involved summarizing a long document was painful — slow, expensive, and the quality varied wildly depending on which model I asked. I'm a performance guy. Slow drives me crazy. So I asked the obvious question: why am I burning a billion tokens to summarize a document when extractive summarization has been a solved-ish problem in NLP since before LLMs existed?

So I vibed it. First version of lede got built over a weekend earlier this year. It worked. Sort of. It was also:

- An ugly baby. Hard-coded paths, magic numbers, dead branches.
- Three projects in a trench coat — the summarization piece, the early version of what became [Chunk Shop](https://github.com/yonk-labs/chunkshop), and a couple of other experiments all jammed into one repo.
- Untested at scale. It "worked" on my laptop, on documents I hand-picked, with one tokenizer.
- Full of bolt-on code from when I thought "oh I should add this" at midnight.

If I'd tried to clean that up paragraph by paragraph, file by file, I'd still be cleaning. The whole thing needed to be ripped apart and rebuilt around what I actually learned from the prototype.

Which is what I did. And the rebuild was *fast,* because by the time I started typing, I knew almost everything about what the thing should be.

## The reverse engineer step

The bridge between the ugly baby and the rebuild is two skills I use constantly: `reverse-engineer` and a downstream skill I call `tech-regret`.

Here's how they work together.

**Reverse engineer** takes an existing codebase and produces a full set of planning docs — a PRD, an architecture doc, a feature inventory, a test plan, sequence diagrams, user guides — the whole package that *would have existed* if you'd built the thing properly from a spec. It's basically: pretend you have to hand this project to a new team and they have to rebuild it without your help. What documents would they need?

That output alone is valuable. But on its own it just describes what exists. It doesn't tell you what to *change.*

That's where **tech regret** comes in. It runs on top of the reverse-engineer output and asks four questions of the project:

1. **What worked?** What parts of this design earned their place? Keep these.
2. **What didn't?** What parts technically run but produce results we don't trust, or scale poorly, or have weird sharp edges?
3. **What do I regret?** What decisions did I (the human) make at midnight that I'd undo now that I've seen the thing run?
4. **What does the LLM regret?** What shortcuts did the agent take to get the prototype shipped that it would do differently if it had unlimited time? (This question surprises people. Models will absolutely tell you what they cut. You just have to ask.)

The output of that pass is the actual blueprint for the rebuild. Not "rewrite lede." Specifically: keep these three modules, break out these two into separate packages, kill these four files entirely, redesign the chunking interface around what we learned about real-world doc shapes, swap out the tokenizer abstraction for a proper trait.

By the end of it, I have a spec that is so much better than what I would have written *before* the vibe phase, because it's a spec built on top of actually having shipped the thing once.

## Rebuild from zero

Then I delete the old repo. Or move it to an `archive/` directory. Either way, I do not start from the existing code.

This part feels wrong every time. It feels like throwing away work. It isn't. The work was the *learning*. The code was the cost of learning. You don't get to keep the code, but you absolutely keep the learning, and the learning is what was valuable.

The rebuild has a few rules I impose on it:

- **DRY but not religiously.** Repeated code is fine if the alternative is a leaky abstraction. Pick your battles.
- **Modular by default.** Anything that could plausibly be lifted into a different project should live behind a clean boundary. This is the lesson I keep relearning. The "monorepo with all the experiments" version of lede was a nightmare. The split-into-focused-modules version is something I can actually maintain.
- **Every problem the A-hole architect found in v1 has to be resolved or explicitly accepted in v2.** Not "addressed." Resolved. If I'm accepting a known flaw, it has to be written down with a reason.
- **The mission brief from the rebuild is stricter than the original.** This is the spot where I lock in the non-negotiables — the things the agent isn't allowed to trade away for performance or simplicity.

The rebuild of lede took less time than the original vibe pass. By a lot. Because the spec was so much better.

## How this works on a team

I've been describing this as a solo workflow because that's how I run my own stuff. But the team version is more interesting and probably more important for anyone reading this who works at a real company.

There are two ways to slot this into how an engineering org actually operates:

**Option A — Product owns the ugly baby.** The PM vibes the prototype to validate the idea. They run the reverse-engineer and tech-regret skills themselves. They walk into the engineering team with a working prototype *and* a clean spec that incorporates the lessons from building it. Engineering takes that and ships the real version. This works if your PMs are technical enough to vibe-code something coherent.

**Option B — Engineering owns the rebuild.** Product or design hands engineering an ugly baby someone vibed, plus the user stories the prototype is trying to serve. Engineering runs reverse-engineer on the prototype, runs tech-regret on it, derives the real spec, and rebuilds. The PM stays in the loop on what gets cut and what gets kept, but doesn't have to be the one wrangling the codebase. This is probably the more realistic path for most orgs.

Either way, the structural change is the same: **prototypes become spec inputs, not code inputs.** Nobody is reading the prototype's source and trying to refactor it into production. The prototype's job is to teach you something. Once you've learned, you build the real thing.

## The thing nobody warns you about

The hardest part of this method isn't any of the technical steps. It's the psychological part where you have to look at a working thing you built and decide to throw the code away.

That feels insane the first time. It still feels weird the tenth time. Every instinct an engineer has says "no, no, I can refactor this, I can salvage this." Sometimes you can. Most of the time, the refactor is going to take longer than a clean rebuild from a better spec, and the result is going to be worse, because you'll keep too many of the original mistakes for sentimental reasons.

You have to be willing to admit your ugly baby is, in fact, ugly. And then let it go.

The good news is the rebuild always — *always* — turns out cleaner than I expect. The spec is better. The code is shorter. The seams are in the right places. And by the time it's done, the original ugly baby has done its job: it taught you what to build. That's worth more than the code ever was.

## Try this on something small

If this method sounds nuts, try it on something low-stakes. Pick a side project you vibe-coded six months ago and forgot about. Run reverse-engineer on it. Run tech-regret on the output. Look at the spec it generates and ask yourself: if I were starting today, would I build it like this?

You already know the answer. The question is whether you're willing to do anything about it.

The ugly baby served its purpose. Time to let it grow up.
