---
title: "Your Agent Doesn't Need Memory. It Needs Six of Them."
date: 2026-06-03
draft: false
tags: ["agent-memory", "ai-infrastructure", "vector-search", "postgres", "rag"]
summary: "\"Add memory to the agent\" sounds like one feature. It is six different jobs that need three different mechanisms. Here is the map, with a concrete example for each."
build:
  list: never
---

Every few weeks somebody tells me they are going to "add memory" to their agent. Like it is a checkbox. Bolt on a vector database, embed the chat history, ship it by Friday.

I have watched this movie. It ends the same way every time. The agent can find a sentence you said last Tuesday, and it still asks you for the fortieth time whether the repo uses pnpm. It "remembered." It just remembered the wrong shape of thing.

Here is the deal: memory is not one feature. It is at least six different jobs sharing one word, and a vector database solves maybe two of them. I have spent twenty years watching teams pick the wrong storage layer for the job in front of them, and the agent era is speedrunning the exact same mistake with fancier embeddings.

## Why this is actually hard

The word "memory" hides six jobs, and those six jobs run on three fundamentally different mechanisms.

Some memory you **search by meaning**. Some memory you **look up by current state**. And some memory you **enforce by policy**, regardless of what anyone asked.

A vector index is the right tool for the first kind and a useless or actively wrong tool for the other two. You cannot answer "what is the current status of feature X" with the ten sentences most semantically similar to "feature X." You cannot enforce "never use em-dashes" by hoping the rule embeds close enough to the prompt to get retrieved. Different jobs, different machinery, different definition of a right answer.

That is the whole reason "just add memory" disappoints. People buy one hammer and discover four of the six things are not nails.

So let me walk the six. For each: when you actually need it, how it differs from its neighbors, and roughly how it is built.

## Group one: recall (search by meaning)

**1. Fact recall.** "When did I paint the picture of the sunrise?" The agent stored a fact somewhere across a hundred past conversations and tool outputs, and now it needs to find it. This is the closest thing to classic retrieval, RAG pointed at your own memory instead of a document pile. Under the hood it is facts stored as rows, found by keyword and vector search fused together, ranked by relevance and how sure you are the fact is still true. In practice: you ask, you get the fact back, plus the source it came from and a confidence on it.

**2. Precedent recall.** "I need to run the quarterly market-trends review again. Have I done this before? What tools did I use, what did I find, and where did I leave it?" This looks like fact recall but it is not. You are not retrieving a fact, you are retrieving a whole past *episode*: the task, the tools, the result, the end state. The unit of memory is bigger and it is structured. Underneath, each task gets stored as an episode with separate fields for what you observed, the supporting detail, and what to do next time. You get back the whole arc: "Last March you pulled the export, ran it through the trends notebook, found three signals, and left it at draft." That is a memory a fact store cannot give you, because a fact is a sentence and a precedent is a story with parts.

## Group two: state (look up the current truth)

**3. Resume, or task-state.** "Pick up feature X. Where are we? Did we finish auth, the API, and the UI? Did we ever build that widget?" This one breaks every retrieval instinct people have. You do not want the most *similar* memories. You want the *current state* of a specific thing, plus which subtasks are done and which never got started. Similarity search is the wrong tool entirely. The right tool is a structured lookup: a task graph with status, where you read the latest head, not a ranked list of guesses. The answer is a status readout. Auth done, API done, UI halfway, widget never started. No vibes, no top-ten, just the state.

If you have ever asked a coding agent to "continue where we left off" and watched it cheerfully redo work it already finished, you have felt the absence of this one.

## Group three: behavior (enforce or suggest)

These last three are not recall at all. They are about acting, and they fire whether or not the query happens to look like them.

**4. Never do this.** A guardrail. "Do not use em-dashes." (Yes, that is a real rule somebody I know holds very dear.) The point of a guardrail is that it has to fire *every time the agent writes*, not only when the prompt happens to embed near the word "em-dash." Mechanically it is a rule attached to a check that runs at action time. In practice, the agent goes to do the thing, the guardrail catches it, the bad output never ships.

**5. Always do this.** A learned skill or preference. "Use pnpm, not npm. Cite your sources." Same shape as a guardrail but pointed the other way, the positive habit instead of the prohibition. It applies when the matching action comes up. Picture the agent reaching for npm out of habit, and the skill quietly redirecting it to pnpm.

**6. Maybe do this.** A suggested best practice. "The last five times you chunked docs, sentence-aware beat fixed windows. Consider it." This is the softest of the six, and it is deliberately not a rule. It is an observation the agent earned by watching, offered as advice. It shows up as a heads-up, not a hard stop. "You usually do it this way, want to?"

## The principle that ties the behavior trio together

This is the design choice I will go to the mat for, and it runs opposite to how most "agentic memory" demos work. The behavior memories should **suggest, not force**.

By default, a learned guardrail or skill or practice is *offered*, surfaced when it is relevant or when you ask, and you stay in the loop. It only enforces itself automatically when you explicitly opt into auto-accept. Memory that silently overrides your judgment is not helpful, it is a coworker who reorganizes your desk while you are at lunch. Earn the suggestion first. Take the wheel only when invited.

## So what does this mean for you

If your "memory" is a vector database and a prayer, you have solved jobs one and two and left four through six on the floor. That is why the agent finds the sentence but repeats the mistake, recalls the chat but loses the thread, knows the fact but ignores the rule.

There is no single strategy that serves a similarity search, a state lookup, and a policy check at once. Anyone selling you one box that does all six is selling you a hammer and calling everything a nail.

## What's next: a post per memory, in detail

This was the map. The territory gets its own series, one post each, going deep on the shape, the implementation, and an honest benchmark that proves whether it earns its keep:

1. **Fact recall** done right: RAG over memory, session-aware, and why it loses to plain document retrieval more often than vendors admit.
2. **Precedent recall**: storing tasks as episodes, and the structured-insight shape that makes "how did I do this last time" answerable.
3. **Resume and task-state**: the state lookup nobody benchmarks, and why your coding agent keeps redoing finished work.
4. **Guardrails**: teaching an agent "never" once and measuring whether it actually sticks (with a regex, not a flaky judge).
5. **Skills**: the positive habit, and the difference between a preference and a guardrail.
6. **Suggested practice plus auto-promotion**: how an agent earns a rule by watching, and when it is allowed to act on it.

One last thing before the next post drops. Go look at whatever your agent calls "memory" and sort it into these six. I will bet you a coffee it is doing one or two of them well and quietly failing the rest. Find the gap first. The model was never the problem.

