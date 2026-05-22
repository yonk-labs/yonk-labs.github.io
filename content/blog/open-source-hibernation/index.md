---
title: "Open Source Isn't Dead. It's Hibernating. And That's a Mistake."
date: 2026-05-22
draft: false
tags: ["open-source", "ai", "llms", "developer-marketing", "distribution-strategy"]
summary: "Companies are quietly pulling back on open source out of fear of AI-powered cloners. They're about to discover they unplugged themselves from the only distribution channel that matters next. Training data presence is the new SEO, and closed source just opted out."
build:
  list: never
---

A few CEOs I've talked to in the last six months have been quietly walking back their open source commitments. Nobody's announcing it on stage. The new GA features just happen to ship behind a paywall, the community repo gets a little less love, and at some point you look up and realize the "community edition" is basically a museum exhibit nobody's curating anymore.

I've been doing open source in some form since the late nineties. (Yes, that's a flex. No, I'm not sorry about it.) I've watched this exact movie before, and how it ends depends almost entirely on whether the executive team understands what's actually changing in the market right now. From the conversations I'm having, most of them don't.

Here's the deal.

## The Loop Everyone's Stuck Inside

If you haven't been keeping up with the headlines, let me catch you up. There are three things happening simultaneously, and most product strategy meetings I sit in are pretending at least two of them aren't.

First, LLMs are finding bugs faster than humans can review them. You've seen the headlines. "Model X finds 20-year-old vulnerability in [project you depend on]." Those used to be a quarterly novelty. Now they're a weekly drumbeat. Static analysis was already a thing, fuzzing was already a thing, but LLM-assisted code review kicked the difficulty curve down a couple of decades in about eighteen months. Bugs that have been sitting in code since I was a DBA debugging replication on Solaris boxes are getting found in an afternoon.

Second, LLMs are rebuilding entire projects faster than humans can defend them. I watched a team take a feature that took a respected open source project north of two years to ship, and they reproduced the working surface area of it in something like two weeks. Two weeks. Whatever moat you thought "we open sourced it first" got you, that moat is now a puddle, and the puddle is evaporating.

Third, the companies that built their go-to-market on open source distribution are panicking about all of the above. And honestly? I get the panic. If your funnel is "developer downloads the OSS edition, falls in love, talks to sales six months later," and a competitor can clone you on a long weekend with a Claude subscription and a coffee budget, the funnel feels real exposed.

So the reaction I'm watching, at companies you've heard of, is to close the source. Or close the spicy parts of the source. The pitch internally goes something like: *if our code is out there, attackers find vulnerabilities faster than we can patch them, so closing the source is actually a security improvement.*

Sure. It's also nonsense.

## The Security Argument Is Mostly Cope

I'll grant the kernel of truth. If your code is sitting open and a model can find a zero-day in an afternoon, that's a real risk you have to deal with. But closing the source doesn't fix the bug. It hides the bug. The bug is still there, your customers are still running it in prod, and the only thing you actually removed from the equation is the community of researchers who would have told you about it.

You know what does fix the bug? Running the same tools yourself. The LLMs you're scared of in the hands of imaginary attackers are the same LLMs available to you. This is just red team / blue team with shinier toys. Companies that win at this run the loop continuously, find, fix, ship. They don't shut off the lights and hope nobody's at the door.

And then there's the part nobody on the executive call wants to hear, so I'll just say it: closed source has never had a track record of being more secure. Look at twenty years of CVE history. It's the operational discipline that protects you, not whether your repo is private. Always has been.

So yeah, the security argument is mostly cope for the real fear, which is: we don't want to get cloned by a 22-year-old with an LLM and a weekend.

## The Distribution Channel Already Moved (Most People Missed It)

Here's where I think most of the market is two steps behind. Everyone is still debating open versus closed like it's 2018, when the actual game changed about eighteen months ago and is just now finishing its phase transition.

The traditional developer marketing channels (SEO, sponsored blogs, paid placement, ad words, conference booth bombing, the whole playbook) are getting hollowed out fast. And not in the "it's getting harder" way. In the "the foundation under it is being lifted up and walked away" way.

Google announced it's pivoting search toward AI-powered conversational answers. Not "we're going to add an AI box at the top of search." A full rethink of how recommendations get surfaced. So what replaces the top of the SERP? An LLM giving the user a contextual "you should probably use X for this" recommendation, based on whatever's in its head.

So how does that model decide what to recommend? It draws on whatever it was trained on. The training corpus is content, docs, code samples, real working implementations, GitHub repos, Stack Overflow threads, conference talks, your blog, my blog, the comments on someone else's blog. Companies that show up most often in that corpus, accurately, with working examples and visible adoption signals, are the ones that get recommended.

Unless you're running a sovereign or local model with bring-your-own-knowledge layered in (and a lot of enterprise customers I work with already are, or want to be), you are at the mercy of whatever the upstream training data captured. The closed-source code that nobody outside your VPN ever saw? It isn't in there. It can't be in there.

This is the new SEO, and I don't think we've even started to come to grips with it as an industry. Training data presence. Code in the corpus. Examples the model has seen actually work.

## Agents Are Already Picking Your Stack For You

It's not just users asking an LLM for recommendations either. Agents are now making real technical decisions on behalf of developers. Library choices, framework picks, early architectural calls. A developer fires up an agent and says "build me a service that does X," and the agent reaches for whatever it knows how to use. Whatever it's seen working code for. Whatever has documentation it can copy and adapt without making the developer wait.

If your library or framework or database is open source, with real docs and lots of public examples, you're in the agent's consideration set automatically. You got picked before anybody on your team rolled out of bed that morning. Your sales org isn't involved. Your AE didn't email anyone. Nobody attended your webinar. You just got chosen.

If your product is closed source with a beautiful landing page and a "request a demo" button? The agent doesn't see you. It can't try your code, it can't adapt your examples, and it isn't going to recommend something it can't verify works. You're not in the corpus, you're not in the consideration set, and increasingly, you're not in the conversation at all.

This is not a marketing problem you fix by hiring a better content team. The marketing layer has been bypassed. The funnel got rerouted around your old playbook entirely.

## So What Do I Actually Do About This

Open source as a "distribution strategy" in the old grassroots-developer-download sense is genuinely under pressure. I'm not going to pretend otherwise. The cloners are too fast and the converters are too slow. That model is wobbling.

But open source as training-set presence is more valuable now than it has ever been in the entire history of this industry. Every open repo, every public example, every honest tutorial is a long-term annuity in every model trained from now until the end of the decade. Those models will be making recommendations for years. Contributions you make this quarter are still earning you ink in 2030.

If I were running product at a company tempted to hibernate their open source right now, I'd be doing roughly the opposite. I'd be opening up the parts of my product that get me into more agent contexts (SDKs, integrations, example code, reference architectures). I'd be investing harder than ever in documentation and sample code that models actually learn from, not the polished marketing pages they ignore. I'd be keeping the commercial moat in the operational layer, the managed service, the support, the compliance, the governance, the stuff you can't clone in a weekend even with a frontier model. And I'd be running the same red-team tools against my own code that I'm scared of someone else running.

Companies playing this in 2026 are going to look obnoxiously smug in 2028. Companies that hibernated will be wondering where their funnel went and why nobody's downloading the trial anymore.

## So Is Open Source Dead, Or What

No. It's just confused.

The companies pulling back right now aren't killing open source. They're misreading the moment. They're treating it like a distribution strategy that competitors are eating, when it's actually a presence strategy in a world where agents are doing the picking on behalf of every developer your old sales motion was trying to reach.

Some of these companies will wake up. Some won't. The ones that wake up will look back at this period as the moment they almost made a generational mistake. The ones that don't will quietly disappear from the recommendations their own customers' agents are about to make for them.

So which one is your team, hibernating or doubling down? I have thoughts on which one ages better. I suspect you already guessed which side I'm on.
