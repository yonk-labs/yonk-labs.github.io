---
title: "llm-judge"
date: 2026-07-01
draft: false
tags: ["python", "llm", "rag", "benchmarking", "evaluation", "cli"]
summary: "Portable CLI for judging RAG and LLM benchmark runs across local, OpenAI-compatible, and cloud providers — a deterministic quick mode, a paraphrase-tolerant LLM-as-judge mode, and a full per-case audit trail for every verdict."
externalUrl: "https://github.com/yonk-labs/llm-judge"
---

**llm-judge** scores RAG and LLM benchmark output fairly and inspectably: a deterministic heuristic mode for cheap smoke tests, an LLM-as-judge mode with a paraphrase-tolerant rubric and strict JSON output, and a dual mode that runs both. Every verdict comes with a per-case audit file — question, chunks, settings, answer, expected answer, judge decision, timing — so a "wrong" call can be checked instead of trusted blindly.

## Why llm-judge?

- **Provider-agnostic by design.** OpenAI, OpenAI-compatible endpoints, OpenRouter, Ollama, Anthropic, Gemini, a shell command, or a mock — the same evaluation runs against any of them.
- **No literal API keys, anywhere.** Keys are passed as environment variable *names*, never values — not in the CLI, not in YAML config. That keeps secrets out of shell history, config files, and benchmark artifacts.
- **Flexible input, not a rigid schema.** JSONL, JSON, or CSV, with alias recognition for common field names (`expected`/`gold`/`reference`, `answer`/`output`/`response`, and so on), plus built-in profiles for RAGAS, LoCoMo, LongBench, HotpotQA, MuSiQue, and more.
- **Honest about failure.** Provider or runtime errors are reported as `ERROR` rows instead of aborting the whole run; retries, resume, and prompt caching handle long benchmark sweeps without babysitting.
- **Reference generation when there's no gold answer.** Given a question and full source context but no trusted expected answer, `llm-judge` can generate a concise reference answer plus the strictly required facts a correct answer must contain — with partial credit for answers that only cover some of them.

## What it's for

- **Scoring RAG pipeline output** — retrieval + generation results against expected answers, at either heuristic speed or LLM-judge accuracy.
- **Cross-benchmark evaluation** — import RAGAS, LoCoMo, LongBench, or QA-benchmark output formats directly via `--profile` instead of reshaping the data first.
- **Multi-judge aggregation** — configure up to three judges in one YAML run and get one final verdict while every individual judge's raw result is preserved.
- **CI-friendly smoke tests** — quick mode's deterministic heuristic scorer catches regressions without an LLM call on every run.

## Quick start

```bash
python3 -m pip install "llm-judge @ git+https://github.com/yonk-labs/llm-judge.git"

python3 -m llm_judge evaluate \
  --input examples/rag_eval.jsonl \
  --mode quick \
  --out .llm-judge-runs/demo
```

## Links

- [GitHub Repository](https://github.com/yonk-labs/llm-judge)
- Related: [pg-raggraph](https://github.com/yonk-labs/pg-raggraph) (a consumer of the `pgraggraph-e2e` profile)
- License: MIT
