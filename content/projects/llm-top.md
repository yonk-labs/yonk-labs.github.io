---
title: "llm-top"
date: 2026-04-12
draft: false
tags: ["python", "llm", "monitoring", "cli", "nvidia"]
summary: "A top-like live terminal dashboard for monitoring LLM inference servers on NVIDIA DGX Spark."
externalUrl: "https://github.com/TheYonk/llm-top"
---

**llm-top** is a `top`-style terminal dashboard for monitoring LLM inference workloads running on NVIDIA DGX Spark (GB10). Get real-time visibility into GPU utilization, memory, processes, containers, and model health — all in one live-updating view.

## Overview

If you're running vLLM, SGLang, NIM, or other LLM inference servers on a DGX Spark, `llm-top` gives you an at-a-glance view of:

- **GPU stats:** SM utilization, memory bandwidth, temperature, power, clock, and memory usage
- **Host stats:** CPU, RAM, core count
- **GPU processes:** PID, name, memory usage, and type (compute/graphics)
- **Containers:** CPU%, memory, network I/O, block I/O, PID counts
- **Model servers:** Port, health, request counts, KV cache usage, RPS, token throughput

## Tech Stack

- **Language:** Python
- **Target:** NVIDIA DGX Spark (GB10)

## Links

- [GitHub Repository](https://github.com/TheYonk/llm-top)
- License: Apache 2.0
