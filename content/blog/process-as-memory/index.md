---
title: "The Process Is the Memory: Why Agentic Memory Should Cache Reasoning, Not Facts"
date: 2026-07-17
draft: false
tags: ["agent-memory", "stele", "ai-infrastructure", "llm"]
summary: "Long-running agents are usually given a memory system that stores facts and retrieves them by similarity, borrowed straight from RAG. We argue that's the wrong default: cheaply re-derivable facts are net-negative to cache, while the expensive, non-re-derivable thing an agent accumulates, process, is exactly what the field under-builds. We present the Agentic Context and Protocol Ledger, validate it with two policy simulations and a four-model adversarial review, and report four empirical results on staleness, dependency-checked reuse, and the mechanisms that make imperfect dependency declaration safe."
build:
  list: never
---

## Abstract

Long-running LLM agents are commonly fitted with a memory system that stores facts and retrieves them by semantic similarity, an architecture inherited from retrieval-augmented generation (RAG). We argue this is the wrong default. For any fact an agent can cheaply re-derive (a database version, a config value, the current branch), retrieving it from a memory system is net-negative: the recall and staleness-validation cost exceeds the cost of re-fetching it live, and a stored stale fact is *strictly worse* than no memory, because the agent trusts the recalled value and suppresses the cheap re-check.

We formalize memory value as the number of agent **turns** it saves, net of recall and verification cost and the expected cost of acting on a wrong reuse. Under this metric the value of caching a re-derivable fact is approximately zero or negative, while the value of caching an expensive multi-step **outcome** or **process** (a distilled procedure, a decision and its rationale, a dead-end and why it failed, a correction) is large and grows with the depth of the work it replaces. Facts retain value as *scope discriminators* and *cheap freshness gates* that select and certify the right cached process. That role is a real and necessary lane (indexing, that is, RAG), but it is a *different* lane from process memory. A complete agent needs both, selected by question type; the field over-builds the fact lane and under-builds the process lane.

We present the **Agentic Context and Protocol Ledger**: a typed, append-only, cost-gated memory of process. We validate its mechanics with two deterministic policy simulations and a four-model adversarial review (codex, gemma, qwen, and a separate codex second-opinion). We report four empirical results: (i) the staleness trap for fact-caching; (ii) that dependency-checked reuse of outcomes is correct but its check cost approaches its derivation cost; (iii) that under-declaring a single dependency collapses correctness to near-naive levels; and (iv) two mechanisms, a post-miss learning loop and a broad-fingerprint canary with a tiered refinement, that restore robustness without requiring perfect dependency declaration. The canary's correctness and savings hold across two hundred randomized drift schedules, a range of dependency counts and cost ratios, and corpus sizes up to ten thousand tasks. We conclude that the unit of agentic memory should be the process, not the fact.

## 1. Introduction

The dominant pattern for agent memory is a vector store of text chunks retrieved by embedding similarity. This pattern works well for question answering over a static corpus, which is the problem RAG was designed for. It generalizes poorly to a *long-running agent acting in a world that changes underneath it*, for two reasons that this paper makes precise and measures.

First, most facts a coding or operations agent would store are **cheaply re-derivable**. "What version of Postgres are we running" is one CLI call. Routing that question through a memory system adds a recall round-trip and a staleness risk, and returns nothing the live check would not. Worse, if the stored value has gone stale, the agent now has a confident wrong answer where it would otherwise have had a correct one. The memory has *negative* value.

Second, the genuinely valuable thing an agent accumulates is not facts but **process**: the multi-step outcomes it derived at cost, the decisions it made and why, the approaches it tried and abandoned, and the corrections it received. This material is expensive to re-derive (often many turns, sometimes irrecoverable once the agent's context is gone) and it does not go stale the way a value does. A dead-end stays a dead-end; a correction stays a correction.

Our thesis is a single sentence: **the real method for agentic memory is the process, not the facts, and the facts are just RAG.** Facts belong in an index that selects and certifies the right process. Process belongs in a ledger.

This is not a dismissal of facts, and we run the fact lane too. The claim is narrower and sharper: facts and process are *different lanes*, a complete agent needs both, and which lane answers a question depends on the question type. A precise-needle question ("what port did we bind") leans on the fact lane (retrieval and packing, RAG); a "have we already done this expensive thing, and is it still valid" question leans on the process ledger. The field has built the fact lane thoroughly and the process lane barely. (This lane-priority claim is workload-dependent: section 10 reports a real coding-transcript follow-up in which the measured token win sat in the retrieval lane, not the process lane.) This paper is about the process lane. The rest of it defines the cost model, presents the ledger design, and reports the benchmark results and the adversarial review that stress-tested it.

## 2. Background and related work

The design we present is not novel in any single component; its contribution is the synthesis and the empirical cost model that drives reuse, store, and eviction decisions. The four-model review independently mapped the design to the following established patterns:

- **Retrieval-augmented generation (RAG).** Retrieve semantically similar text, place it in context, let the model judge applicability. Appropriate for static-corpus QA; the failure mode in an agentic setting is that it treats applicability as a similarity judgment rather than a validity check.
- **Event sourcing and CQRS.** An append-only log of typed events, from which current-state views are projected. The ledger is an append-only log; a correction is a new linked record, never an overwrite.
- **Memoization with precondition checks.** A cached result plus a validity predicate. The cached unit here is a unit of *reasoning*, not a pure function call.
- **Assumption-based truth maintenance systems (ATMS).** Conclusions are valid only under explicitly recorded assumptions, and are invalidated when an assumption fails. This is the formal ancestor of our dependency checklist.
- **Build-system dependency invalidation** (Make, Bazel, Skyframe). A derived artifact is reused only if its declared inputs are unchanged. The ledger applies the same discipline to derived reasoning.
- **Cost-aware cache replacement** (GreedyDual-Size and relatives). Retention weighted by recompute cost. Our cost spine is the agentic analogue: keep what is expensive to re-derive and often reused.
- **Case-based reasoning** and **Reflexion-style procedural memory.** Reuse of prior solved cases, and storage of corrections and failed strategies. These are the high-value records in our taxonomy.

The framing that ties these together, and which the review converged on, is that agent memory should be **validated reuse of derived work**, not a slow key-value store for facts.

## 3. The cost model: why fact-memory is the low-value corner

Let an agent be able to produce a result `R` either by recalling it from memory or by re-deriving it. The net value of durably storing `R` is

```
V(R) = (C_derive - C_verify - C_recall) * N_reuse  -  C_store  -  P_stale * C_error
```

where `C_derive` is the turns to recompute `R` from scratch, `C_verify` is the turns to confirm a recalled `R` is still valid, `C_recall` is the turns and context cost to bring `R` into the working set, `N_reuse` is the number of times `R` is reused, `C_store` is the one-time write cost, and `P_stale * C_error` is the probability the recalled `R` is wrong times the cost of acting on it. `P_stale` is not a free parameter: it is the false-valid-reuse rate the benchmarks in section 6.2 measure directly, so the formula is grounded in an observed quantity rather than a guessed distribution.

Cost is a **vector, not a scalar**. We measure each term in both **turns** (latency, round-trips, opportunities to drift) and **tokens** (dollar cost and context-window budget). The two diverge: a derivation can be few turns but many tokens (one large document read) or many turns but few tokens (many small CLI calls). The binding constraint chooses the currency: the formula is evaluated *within* one currency, never by summing turns and tokens, so it is dimensionally consistent. A subtle consequence is that *recall spends tokens to save turns*: pulling a record into context consumes context budget to avoid the turns of re-derivation, so a record's own footprint must be subtracted from its value. This is why a useful record stores the *distilled* outcome (small footprint) rather than the raw derivation trace, while never compressing away the assumptions that make it safe to reuse.

One corollary follows immediately. For a **terminal, cheaply re-derivable fact**, `C_derive` is approximately 1 turn and `C_recall` is at least 1 turn plus a staleness risk, so `V(R)` is approximately zero before subtracting storage and error cost, that is, negative. For a **multi-step outcome**, `C_derive` is large (a distilled "best practices for tuning Postgres 17 for this workload" costs roughly five turns to derive: get the version, open the right docs, find the tuning section, distill, validate), so `V(R)` is strongly positive and grows with derivation depth.

This is the formal statement of the thesis. **The payoff of memory scales with the turn-depth of the work it replaces.** A benchmark on single-fact recall is measuring the corner where `V` is smallest by construction.

### 3.1 The staleness trap

The negative-value case is not merely "no benefit." It is active harm, and we measured it. When an agent stores a re-derivable value and the world changes, the agent trusts the stored value and *suppresses the cheap re-check it would otherwise have run*. In a controlled real-LLM experiment (gemma-class model, reported in our return-format benchmark), storing a stale atomic value produced 0% task accuracy under efficiency pressure, versus 100% for either no memory or for storing a *verification method* (how to re-derive the value) instead of the value. Dating the stored value did not help. Storing a re-derivable value is strictly worse than storing nothing.

### 3.2 The two roles a fact still plays

Discarding fact-memory entirely would be an over-correction. A fact such as `dbengine = MySQL` is not worthless; its value is **relational, not intrinsic**. It plays two roles, neither of which is "an answer to retrieve":

1. **Scope discriminator.** Tuning MySQL is a different process from tuning Postgres. The fact is the filter key that selects *which* cached process applies. It must be stored, bound to the processes it discriminates. But it is never the target of a standalone lookup; re-fetching it live is cheaper and never stale.
2. **Freshness gate.** Store the expensive outcome, the scope it is valid under, and a cheap re-check (a *verification method*). On recall, re-run the cheap check ("still Postgres 17?"); if the anchor holds, reuse the expensive outcome; if it moved, re-derive. A time-based TTL is a crude proxy for this; the real gate is re-verifying the outcome's key assumption.

Both of these roles are *indexing and validity-gating*. That is RAG and metadata filtering. The fact is the index; the process is the content. Hence: the facts are just RAG.

Read correctly, "the facts are just RAG" names *which lane* facts live in; it is not a claim the lane is worthless. The fact lane is a well-studied retrieval-and-packing problem with its own tradeoffs, and how retrieved facts are packed is itself question-type-dependent. In our own retrieval experiments (LoCoMo, n=50), an extractive, deduplicated minimized-fact packing won precise-needle recall by denoising without paraphrasing the graded detail, while a hint-biased summary packing was better suited to synthesis over long noisy history (the synthesis advantage sits within benchmark noise at the tested scale). There is no universal best packing. That alone is evidence that fact-retrieval is a distinct lane, with its own internal choices, sitting *beside* the process ledger rather than being replaced by it.

## 4. The Agentic Context and Protocol Ledger

The ledger stores **process** as typed, append-only, assumption-bound records.

### 4.1 Record kinds, by value

| kind | example | derive cost | role |
| --- | --- | --- | --- |
| `outcome` | a distilled multi-step result ("PG17 perf tuning for this workload") | high | the headline cached work |
| `procedure` | a reusable how-to ("how we cut a release here") | high | replaces a multi-turn chain |
| `decision` | a chosen direction and rationale ("Redis Streams over Kafka, Kafka ops overhead too high") | high | stops re-litigation |
| `dead_end` | a tried-and-failed approach and why ("global lock deadlocks under load") | high | stops re-attempting |
| `completion` | a done/reviewed marker ("spec X approved") | medium | stops redundant rework |
| `verification_method` | how to cheaply re-derive or check a volatile fact | low (it *is* the gate) | scope/freshness |
| `observation` | a witnessed fact bound to a process ("PG16 used in workflow X at T") | low | audit/scope |

Only the first four typically justify the cost machinery. `observation` and `verification_method` are scope and gate material, never standalone retrieval targets. The bottom rows are the index; the top rows are the memory.

### 4.2 Record shape

Each record is immutable. Corrections and reversals are new linked records. Running usage statistics live in a separate projection so the record stays append-only. Append-only is for auditability, not unbounded growth: a projection supplies current-state views, supersession links resolve a query to the live record, and cost-aware compaction (evicting records with low value-times-reuse) keeps the hot retrieval set small. Without those, an append-only log degrades into retrieval noise, a failure mode the design must prevent, not inherit. The load-bearing fields are:

- **Payload**: a *distilled* title and body, plus evidence references (required, non-empty).
- **Scope**: structured discriminators (`dbengine`, `version`, `project`, `branch`) that *route* to candidate records.
- **Dependencies**: the validity boundary, the bundle of assumptions the outcome depends on, each carrying its own cheap re-check. These are the things an agent must verify before reuse, and how completely they are declared is the central open problem (section 9).
- **Cost spine**: `derive_turns`, `derive_tokens`, `verify_turns`, `verify_tokens`, `footprint_tokens`. The empirical inputs to `V(R)`.
- **Trust**: authority (a *default* ordering, user > system > agent-inference > observation), confidence, and provenance. Authority informs *trust*, not *validity*: a fresh observation can outrank a stale user statement, so the ordering is a prior that a current check overrides, never a fixed total order (see section 7).

### 4.3 The retrieval protocol is a planning step

Memory is not consulted to fetch an answer. It is consulted during the agent's **planning** step, which answers "what information do I need, and how do I get it." In that step memory plays three roles:

1. **Route.** Match scope discriminators to candidate records ("you asked about Postgres, here is the stored process").
2. **Fill in.** Supply a discriminator the question omitted, or a best-guess prior ("you did not say which database; this agent used Postgres last session"). This is a continuity fact the agent cannot cheaply re-fetch, so recall is legitimate here.
3. **Dependency checklist.** The stored process declares the inputs it requires. The plan resolves each: provided in the question, recalled, or fetched live. If it cannot resolve them, it returns "I need these N things, go get them."

The reuse decision is then: if scope matches, every dependency check passes within a verify budget, and `V(R) > 0` in the scarce currency, reuse the record as executable; if some dependency is unresolved or unverifiable, treat the record as advisory context (a *hint*, never acted on as truth without re-derivation); otherwise re-derive, and re-measure the cost.

## 5. Experimental method

All results below come from **deterministic policy simulations**. The cost-gated, dependency-checked reuse mechanism does not yet exist in production; the honest path is to simulate the policy and measure it before building it. Two simulations are used.

**Evolving-world simulation.** A long-running agent answers value queries across hundreds of sessions while facts about its world change underneath it (a database migrates Postgres to MySQL, a Python pin moves, a tool is deprecated). The agent policy is held constant across arms; only the memory subsystem varies, so any delta is attributable to memory. The simulation isolates the issue-#72 failure class ("entity-named-by-its-value"), where the subject is labeled after the value it carries, so each change mints a new subject identity and supersession never fires. Backend: PostgreSQL.

**Outcome-reuse simulation.** An agent repeatedly produces a multi-step outcome whose correctness depends on several environment dimensions that drift over time, one of them silently. This measures the *high-value* corner (turns-to-outcome, not single-fact recall) and, critically, the **false-valid-reuse rate**: how often a policy reuses a stale outcome and acts on it. It is a pure policy simulation with an explicit cost model (`derive=5`, `check=1`, `recall=1` turns).

We report turns (the scarce currency), accuracy, and false-valid rate. We do not claim wall-clock or token-cost numbers from these simulations; they measure policy behavior, not a production system.

## 6. Results

### 6.1 Fact-caching fails on changing facts (evolving-world)

Store-side staleness on the issue-#72 "entity-named-by-its-value" class, PostgreSQL, 440 sessions. Lower is better; the target gate is 0.10.

| arm | value-class staleness | agent accuracy |
| --- | --- | --- |
| no-memory (re-derive every query) | n/a (stores nothing) | 0.95 |
| naive-append (store every fact) | 1.00 | 0.91 |
| supersession registry | 1.00 | 0.91 |
| supersession + role-anchor fix | 0.67 | 0.91 |
| **verification-method ledger** | **0.00** | **1.00** |

Every arm that stores the *value* leaves stale values active, and is *less accurate than having no memory at all*, because it sometimes trusts a stale note. Supersession cannot fix the #72 class: when the value is the identity, each change is a new subject, so the old value is never retired. The only arm that reaches zero stores the *method* (re-derive on read), not the value.

In a silent-change variant (PostgreSQL, 600 sessions), a freshness-bounded reuse of a witnessed observation ("trust for N sessions, then re-derive") cut turns by 33% and tokens by 44% versus always re-deriving, at zero staleness, while a trust-forever cache went permanently stale on the unannounced change. The freshness window is load-bearing.

### 6.2 Process-caching works, but the gate is the whole story (outcome-reuse)

120 tasks. `derive=5`, `check=1`, `recall=1` turns. Lower turns and false-valid are better; higher accuracy is better.

| arm | accuracy | false-valid | turns/task | note |
| --- | --- | --- | --- | --- |
| no-memory | 1.00 | 0.00 | 5.00 | safe ceiling, dearest |
| naive-cache (no checks) | 0.25 | 0.75 | 1.07 | cheap and mostly wrong |
| ledger, all 3 deps checked | 1.00 | 0.00 | 4.03 | correct, but must be perfect |
| ledger, 1 dep under-declared | 0.33 | 0.67 | 3.05 | one miss is near-naive |
| ledger, learns the miss (lag 2) | 0.98 | 0.017 | 3.71 | recovers, if detected |
| ledger, broad-fingerprint canary | 1.00 | 0.00 | 2.30 | robust without perfect declaration |
| ledger, tiered (canary + narrow check + learn) | 0.98 | 0.017 | 2.53 | churn-immune |

Five findings, in order of importance:

1. **Full declaration is correct by construction; the interesting cases are imperfect.** In a deterministic simulation, a fully-declared dependency set makes reuse correct by definition, so the fully-declared arm's zero false-valid is the baseline, not a finding. The empirical content is the *contrast*: naive caching with no checks is 75% wrong, and the dependency checks are what buy correctness back. The simulation's value is the relative behavior across declaration regimes (findings 2 to 5), not the absolute score of the perfect-information arm.
2. **The check cost approaches the derivation cost.** The fully-declared ledger saves only 19% of turns, because verifying three dependencies costs nearly as much as re-deriving. Reuse pays only when derivation is *deep* relative to its dependency count.
3. **Under-declaration is near-catastrophic.** Omitting one of three dependencies pushed the false-valid rate from 0 to 0.67, almost as bad as no checks at all. **The gate is only as good as the declared dependency set.**
4. **Declaration need not be perfect if misses are detected.** A post-miss learning loop, which learns the missed dependency after the failure surfaces downstream, collapsed the false-valid rate from 0.67 to 0.017, at lower cost than declaring everything upfront. But its value is entirely contingent on detection: with the failure never surfacing, it degraded exactly to the under-declared arm. *The linchpin moves from "declare perfectly" to "detect a bad reuse."*
5. **Robustness without perfect declaration is achievable.** A single cheap broad fingerprint of the environment catches undeclared drift, so an under-declared canary arm is correct (zero false-valid) and is in fact the cheapest correct arm, because one fingerprint check replaces N per-dependency checks. Its cost is over-invalidation: it also re-derives when irrelevant state churns.

### 6.3 The brittleness fix and its tradeoff

Requiring perfect declaration is itself naive; it is naive caching with extra steps. The canary replaces "declare every dependency exactly" (brittle, one miss is fatal) with "bound the relevant slice and fingerprint it" (forgiving, only drift *outside* the slice slips through). Bounding a slice is a much coarser and more robust thing to get right than enumerating every dependency.

The canary's cost is over-invalidation, and it scales with churn. The **tiered** arm removes that cost: it checks the cheap broad fingerprint first, and only on a trip checks a *narrow* fingerprint (the declared dimensions) to tell real drift from noise instead of blindly re-deriving. A noise-only trip is reused; a genuinely-undeclared-relevant drift is reused once, then learned. The result is near-immune to churn:

| churn level | canary turns/task | canary re-derives | tiered turns/task | tiered re-derives |
| --- | --- | --- | --- | --- |
| low (noise every 10 tasks) | 2.30 | 12 | 2.53 | 4 |
| high (noise every 2 tasks) | 3.50 | 60 | 2.58 | 4 |

The canary degrades toward no-memory as churn rises; the tiered arm does not move. The crossover is clean: at low churn the plain canary wins (simpler, zero false-valid); as churn rises, the tiered approach wins decisively, paying only a small fixed learning lag the canary avoids.

### 6.4 The canary holds across schedules, scale, and cost ratios

The 2.30 figure comes from one hand-built drift schedule, so we stress the canary further. Across two hundred randomized schedules (varying drift timing, dependency count, and noise sources, each on its own seed) the canary stays at zero false-valid with full accuracy, and never costs more than always re-deriving; mean cost is 2.83 turns per task, ranging from 2.05 to 4.25. The zero-false-valid property is structural, not lucky: the canary reuses only when its fingerprint is unchanged, so it can act on stale information only when drift falls *outside* the fingerprinted slice (the semantic blind spot of section 10).

Two further results sharpen the case for a broad fingerprint over per-dependency checking. First, per-dependency checking does not scale. Once the dependency count reaches the point where verifying every dependency costs as much as re-deriving (four dependencies under this cost model), the fully-declared arm stops reusing entirely and collapses to the cost of no memory, while the canary's single fingerprint keeps reusing at any dependency count. Second, that collapse point is not a fixed number; it moves with the cost ratio exactly as the arithmetic predicts (from three to seven dependencies across the cost models we swept), which shows the qualitative finding is a property of the mechanism, not an artifact of the chosen `derive=5`, `check=1` numbers. Finally, the savings are not a small-sample effect: from thirty to ten thousand tasks the canary holds a flat 54% turn saving at zero false-valid, and with up to two hundred entities drifting at once each keeps its own record and fingerprint, so coexisting drifts never cross-contaminate.

## 7. Adversarial validation

The design and the resulting record specification were each submitted to a four-model review (a multi-model debate across codex, gemma, and qwen, plus an independent codex second-opinion). The review was strongly convergent and is summarized here, including where it disagreed.

**Agreed.** The economic framing (value equals turns saved minus cost and risk) is sound. The design is event sourcing plus memoization plus dependency-based cache invalidation, not RAG. The strongest single objection, raised by every model, is that a cheap freshness gate is **underpowered**: re-checking one anchor catches *identity* drift ("still PG17?") but not *semantic* drift (the workload shifted, the table grew 100x, a managed host overrode the config). Re-checking one anchor while validity depends on a bundle of assumptions yields **false-valid reuse**, which is worse than no memory. Our dependency-checklist and the empirical results in section 6.2 are the direct response: the process declares its full dependency set, resolved at planning time, and we measured exactly how badly an incomplete set fails.

**Required revisions the review surfaced**, now recorded in the specification: replace executable check strings with a typed, sandboxed check contract (a stored shell command is a remote-code-execution and portability hole); require dependency *classes* per record kind plus a write-time critic pass and a post-miss learning loop; forbid `recall` as a *validation* source (memory validating memory lets stale assumptions reinforce themselves); add a reuse audit and conflict/current-view semantics; and treat the net-value formula as a probabilistic heuristic with a candidate budget, not a proof.

**Disagreements, not papered over.** Whether "authority gates execution" is a category error (most models: a user can be wrong, so source-trust is not factual validity) or a defensible risk-based permission model (one model). Whether verification-method recursion is fundamental (needs primitive base checks) or manageable (precompute checks at write time). We resolved the first toward "authority informs trust, not executability," and the second toward "primitive built-in checks are the base layer."

## 8. Comparison with deployed agent-memory systems: Letta and Mem0

The two most widely deployed agent-memory systems, Letta (the productization of MemGPT) and Mem0, sit on opposite sides of the argument in this paper. Both are strong systems for the workload they target. Comparing them clarifies what the process ledger adds, and equally where it does not compete.

### 8.1 Letta (MemGPT): OS-inspired context management

MemGPT (Packer et al., 2023, arXiv:2310.08560) frames the LLM as an operating system and its context window as virtual memory. It manages a two-tier hierarchy: an in-context "main context" (fast, like RAM) and an out-of-context external store (slow, like disk), and the agent pages information between them through function calls. Letta productizes this into a runtime with three tiers: **core memory** (small labeled blocks that live in the context window and are self-edited via `core_memory_append` and `core_memory_replace`), **recall memory** (searchable conversation history), and **archival memory** (a vector store queried by tool call). The defining mechanism is **self-editing**: the agent decides, by its own reasoning, what to write to each tier. Its targets are unbounded conversation and large-document analysis, that is, keeping a coherent persona and history across sessions that exceed the context window.

The strength is generality and agent control. The documented weakness is that memory quality depends entirely on the model's judgment. There is no structural notion of whether a stored item is still *valid*, no dependency boundary, and no cost model governing whether recalling an item beats re-deriving it. Letta manages where information lives. It never asks whether the cached reasoning is still safe to reuse.

### 8.2 Mem0: fact extraction, consolidation, and retrieval

Mem0 (2025, arXiv:2504.19413) is the purest instance of the pattern this paper calls "facts are RAG." It runs a two-phase pipeline: an **extraction** phase uses an LLM to pull salient facts and preferences from a conversation, and an **update** phase performs a semantic search for similar existing memories and lets the LLM choose one of four operations, **ADD, UPDATE, DELETE, or NOOP**, to keep the fact base current and non-redundant. A graph variant, Mem0g, additionally stores entities and relation triplets. On the LOCOMO conversational-memory benchmark, Mem0 reports a 26% relative improvement in an LLM-as-judge metric over OpenAI's native memory, with roughly 91% lower p95 latency and over 90% token savings.

Mem0's architecture *is* the fact-centric default. Its unit is the atomic fact; its maintenance operation, UPDATE or DELETE to keep facts current, is precisely the supersession strategy that our evolving-world benchmark (section 6.1) shows fails on the "entity-named-by-its-value" class, where each change mints a new subject identity and the old value is never retired. For *durable* facts (a user's stated dietary preference), this is exactly right, and Mem0 is purpose-built for it. For *volatile, re-derivable* facts (a database version), section 3.1's staleness trap applies: storing and updating the value is net-negative against a one-call re-check. And for *expensive multi-step outcomes*, Mem0 has no representation at all, because an outcome is not an atomic fact.

### 8.3 What the ledger adds, and what it does not

| dimension | Letta (MemGPT) | Mem0 | Process Ledger (this work) |
| --- | --- | --- | --- |
| organizing unit | memory tiers + self-edited blocks | extracted atomic facts / preferences | typed process records (decision, dead-end, procedure, outcome) |
| core operation | page in and out of context; self-edit | extract, then ADD/UPDATE/DELETE/NOOP | cost-gated, dependency-checked reuse |
| retrieval | tool-driven search (vector + recency) | semantic search (vector, optional graph) | scope-route, validity-gate, net-value rank |
| staleness handling | agent judgment (self-edit) | UPDATE/DELETE to keep facts current | observations append-only; current truth re-checked or re-derived |
| validity model | none structural | similarity + LLM-decided update | explicit dependency checklist + cost spine |
| value metric | context fit, coherence | factual accuracy (LOCOMO) | turns saved, false-valid rate |
| target workload | unbounded chat, document analysis | conversational personalization | agentic process reuse in a changing technical environment |

Two qualifications. First, this is not a claim that the ledger "beats" Letta or Mem0 on their benchmarks. LOCOMO measures conversational recall; our benchmarks measure validated reuse of derived work in a world that changes underneath the agent. These are different workloads, and a cross-benchmark number would be meaningless. Second, the systems are largely **complementary**. The ledger is a layer, not a store: its records could persist in Letta's archival tier or Mem0's vector store. What it adds on top is the part neither system has: a typed *process* unit, an explicit *validity boundary* (the dependency checklist), and a *cost model* that decides reuse versus re-derivation in turns and tokens. Letta optimizes context placement; Mem0 optimizes fact currency; the ledger optimizes the safe reuse of expensive reasoning. Framed as lanes: Letta and Mem0 build the fact and context lanes, and the ledger builds the process lane. A production agent likely wants all three behind a selector that routes each query to the lane that answers it, a similarity or recall question to the fact lane, a "have we done this expensive thing, and does it still hold" question to the process lane. The contribution here is not to replace the fact lane but to name and measure the process lane the deployed systems leave empty.

## 9. Discussion

The results compose into a single argument.

Fact-memory, the RAG-shaped default, is the low-value and actively-harmful corner (sections 3.1 and 6.1). Facts earn their place only as scope discriminators and freshness gates (section 3.2), which is an indexing role. The valuable unit is process, and caching it is worthwhile in proportion to the turns it saves (section 3). Caching process safely requires checking the assumptions it depends on (section 6.2, findings 1 to 3). Requiring those assumptions to be declared *perfectly* is brittle, but two mechanisms remove the brittleness: learning missed dependencies from detected failures (finding 4), and a broad fingerprint that catches undeclared drift, refined by a tiered narrow check to remove its over-invalidation cost (findings 5, section 6.3).

The through-line for practitioners is a reordering of where effort goes. The hard problem sits below both storage and retrieval ranking, in **the validity boundary**: knowing what a piece of cached reasoning depends on, and detecting cheaply when one of those dependencies has moved. Our data shows the cache machinery itself is sound; the residual risk lives entirely in declaration completeness and in detection. Declaration does not have to be perfect: the relevant slice has to be bounded, and a wrong reuse has to be noticed.

## 10. Limitations

These are policy simulations, not a production system. The outcome-reuse results use a fixed cost model (`derive=5`, `check=1`); the qualitative findings (mechanism works, check cost approaches derive cost, under-declaration is near-catastrophic, learning and canary restore robustness) are robust to the ratio, which we verified directly by sweeping it: the dependency count at which per-dependency checking stops paying tracks the cost ratio exactly as the arithmetic predicts. The exact turn savings, however, are not a production claim. The learning loop assumes a detection mechanism with a fixed lag; in the real world detection is variable, sometimes expensive, and for a truly silent failure may never occur, in which case the learning arm provably degrades to the under-declared arm. A second structural limitation: the fingerprint and dependency checks catch *syntactic* drift (a tracked value changed) but not *semantic* drift, where meaning shifts while the tracked value holds, for example an API schema that changes under a stable version string. We measured this boundary: under such a hidden shift the canary and the fully-declared ledger act on the stale outcome at the identical rate, so the blind spot is a property of syntactic fingerprinting in general, not of the canary specifically, and only always-re-deriving is immune. Catching semantic drift needs a semantic check (does the result still match the expected shape), not a hash, and is unsolved here. A related open problem is that dependencies are *declared*, not *inferred*; a production system would need to infer the dependency set from causal traces and a write-time critic, not rely on the agent listing it correctly. The cost spine measures the cost *this* agent paid, including its own inefficiency, which is the correct number for that agent's reuse but noisy for memory shared across agents of differing skill. Finally, the evolving-world numbers are same-harness comparisons; they are not comparable to cross-vendor memory benchmark figures reported under different harnesses.

A follow-up has begun moving from simulation toward real data, and the early result both sharpens and bounds the thesis. We parsed real coding-agent transcripts (six projects, eighty-five session groups, roughly 11.7 million tokens of file reads) to locate where memory removes inference tokens in practice. Two findings bear on this paper. First, the dependency-boundary claim of section 6.2 is independently revalidated outside simulation: the only retrieval that captured the real saving was dependency-aware (resolving the call graph), which recovered the needed context in thirty of thirty cases at six percent of full-file tokens, where a naive span window recovered one of thirty. Structure-aware beats similarity-aware for the same reason a declared dependency set beats a single anchor. Second, and against this paper's lane-priority framing, the high-value lever for coding agents was not process reuse but retrieval: agents over-fetch, reading whole files when a single function was needed, which accounts for roughly sixty-five percent of edit-anchored read tokens. The command-level and outcome-level reuse this paper measures in simulation did not reproduce on real coding transcripts, because coding agents rarely re-derive the same expensive outcome, so the recurrence the canary depends on was scarce. We therefore scope the claim that the field under-builds the process lane to the workloads this paper targets (long-running agents in a changing technical environment, and conversational personalization), and we note that for coding agents specifically the measured token win sits in the retrieval lane, in bounding what a single read pulls in. The process-lane simulation results stand as simulations; their real-transcript confirmation remains open for the evolving-world and conversational workloads where outcome recurrence is plausible, and came back negative for the coding-agent workload where it is not.

## 11. Conclusion

An agent that has been working a problem for hours has accumulated something worth keeping. It is not the database version, which it can re-read in one call. It is the chain of expensive, non-re-derivable reasoning: the outcomes it distilled, the decisions it made, the dead-ends it ruled out, the corrections it absorbed. A memory system that stores facts and retrieves them by similarity captures the cheap, perishable thing and misses the expensive, durable thing.

The fix is to make the **process** a unit of memory: typed, append-only, cost-gated, and bound to the assumptions that make it safe to reuse. Facts keep their job, as the index that routes and certifies, which is what RAG is for; the process lane sits beside it, the one the field under-builds. The headline is a reordering of the default: index the facts, *and* cache the reasoning, two lanes, with the process treated as memory in its own right. The process is the memory the field is missing.

## References and artifacts

This paper synthesizes established patterns; the contribution is the cost model and the empirical validation. Conceptual lineage: event sourcing and CQRS; assumption-based truth maintenance systems (de Kleer); build-system dependency invalidation (Make, Bazel, Skyframe); cost-aware cache replacement (GreedyDual-Size); case-based reasoning; and Reflexion-style procedural agent memory.

Compared systems (section 8): Letta / MemGPT (C. Packer et al., "MemGPT: Towards LLMs as Operating Systems," 2023, arXiv:2310.08560) and Mem0 ("Mem0: Building Production-Ready AI Agents with Scalable Long-Term Memory," 2025, arXiv:2504.19413).

Reproducible artifacts ([stele](https://github.com/yonk-labs/stele)):
- `benchmarks/evolving_world.py` (sections 6.1) and `benchmarks/return_format.py` (section 3.1).
- `benchmarks/outcome_reuse.py` (sections 6.2, 6.3), with arms `no-memory`, `naive-cache`, `ledger-v1`, `ledger-underdecl`, `ledger-learn`, `ledger-canary`, `ledger-tiered`.
- `benchmarks/external/cascade_packing_matrix.py` (section 3.2, the fact-lane retrieval-and-packing experiment), with results in `benchmarks/runs/cascade-shootout/`.
- `docs/specs/ledger-record-spec.md` (record schema, retrieval protocol, the four-model review, and the v1 validation).
