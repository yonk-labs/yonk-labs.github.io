---
title: "The Yonk-isms"
date: 2026-04-12
draft: false
tags: ["humor", "yonk-isms", "hot-takes"]
summary: "A running list of things I say too often, beliefs I will not shut up about, and the recurring bits that turned into actual brand."
---

After 20+ years of ranting at conferences, recording podcasts, and explaining databases to people who'd rather be doing literally anything else, you develop a vocabulary. This is mine. Some of it is useful. Some of it is me being a smart-ass. All of it has shown up in a meeting where somebody stared at me and said *"wait, is that a bit, or are you serious?"*

The answer is always *yes.*

## The hot takes I will not shut up about

### "Database design is a lost art."

This is the one that gets the most eye-rolls and the most slow-nodding-in-agreement, usually from the same people. We stopped teaching it. We stopped caring about it. And now half the "AI problems" I see are actually "somebody didn't normalize their schema" problems wearing a trench coat.

### "In AI Land, the hard problem is always data engineering, not database selection."

Your RAG pipeline is not failing because you picked Postgres over Milvus. It's failing because your chunking strategy is garbage and your embedding model has no idea what domain you're in. I will repeat this until I lose my voice.

### "Right-sized AI."

Not every problem needs a 400-billion-parameter model. A 7B model running locally with a good retrieval layer and honest evaluation will beat GPT-4 on your specific task 60% of the time, at 5% of the cost, with none of the data leaving your building. You want *fit*, not *flex.*

### "Small things in application design have a big impact on database performance."

I've spent entire consulting engagements fixing a single bad ORM pattern. One `SELECT *` in a loop can take down a cluster. One missing index can cost a company millions. The people who design the app are making performance decisions for the DBAs whether they know it or not.

### "Show me the methodology, or your benchmark is marketing."

Any benchmark without workload, concurrency, hardware, dataset size, and version is not a benchmark. It's a press release. If your comparison graph starts the Y-axis at 80% to make a 2% difference look like a victory, I am *already* mad at you.

---

## The Oreo Analogy

I came up with this one to explain where PostgreSQL sits in the modern AI stack, and somehow it stuck. The story goes:

> Your AI stack is an Oreo. The top cookie is the model providers — OpenAI, Anthropic, Google, the usual suspects. The bottom cookie is the agent frameworks — LangChain, LlamaIndex, AutoGen, whatever's trendy this week.
>
> But here's the thing. **The Oreo isn't the cookies. The Oreo is the double stuff in the middle.** The data layer. The governance layer. The retrieval layer. The thing that actually knows what your enterprise data is and who's allowed to see it.
>
> That's the database. That's PostgreSQL. And if you don't get the middle right, no amount of cookie is going to save your cookie.

People have stolen this one. I don't mind. It works.

---

## The Verbal Tics

Things I apparently say a lot, based on transcripts I've been subjected to:

- **"Look, ..."** — how I start any sentence where I'm about to disagree with you politely
- **"Here's the deal..."** — how I start any sentence where the disagreement is no longer going to be polite
- **"So what does that actually mean?"** — my defense mechanism against hand-wavy marketing
- **"I have thoughts."** — said right before I have more than thoughts, I have a 40-minute rant
- **"Sorry, not sorry."** — deployed after any statement a vendor is going to be mad about
- **"(don't @ me)"** — parenthetical, always in writing, usually right after I've said something everybody is going to @ me about
- **"The HOSS"** — referring to myself in the third person, tongue firmly in cheek, because if I'm going to have an absurd title I'm going to lean into it

---

## The Recurring Bits

### Wrestling analogies for everything

I build wrestling sims in my free time. Occupational hazard: I now explain every technical concept via wrestling. "Postgres and MongoDB aren't enemies, they're a tag team." "Your DBaaS provider is your promoter and you're the talent — know the difference." "Database replication is a face-heel turn in slow motion."

If this makes no sense to you, congratulations, you are a healthy person. If it does make sense to you, we need to have a beer.

### Cooking metaphors for team building

I cook for my teams. Sometimes over video calls, which is exactly as weird as it sounds. I will 100% explain customer success strategy by making you watch me make a risotto. The metaphor is: you cannot rush it, you cannot skip the stirring, and if you walk away from the stove you will deserve what you get. Database operations are the same. Team building is the same. Most things are the same.

### Referring to past selves in the third person

"There was a version of me in 2011 who thought MongoDB was going to eat everything. That guy was young and wrong. I bought him a beer and told him I was sorry."

### The fact that I picked my own title

HOSS stands for Head of Open Source Strategy. I picked it. When I got to Percona the second time and they asked what my title should be, I said *"The HOSS"* and everybody laughed and I said *"no, seriously"* and now it's on multiple conference badges.

---

## The Retired Bits

These used to be in rotation. They have been lovingly put out to pasture:

- **"MongoDB is web scale."** — the joke was funny in 2010. Let it go.
- **"NoSQL is just SQL with fewer letters."** — still accurate, but I don't want to start another war.
- **"Kubernetes is a distributed system for distributing the problem of running a distributed system."** — retired because it's more depressing than funny now.

---

If I say something in a podcast and you want me to add it to the list, [let me know](/about/#find-me). The canon expands.
