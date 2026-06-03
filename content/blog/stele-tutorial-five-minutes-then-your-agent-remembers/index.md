---
title: "Stele Tutorial: Five Minutes, Then Your Agent Remembers"
date: 2026-05-23
draft: false
tags: ["stele", "agent-memory", "tutorial", "mcp", "postgres", "ai", "agents"]
summary: "The hands-on follow-up to the why-I-built-it post. Real commands, real outputs: install Stele, wire it into your agent, store artifacts with citations, supersede facts, time-travel with as_of, stash oversized tool output, and run recall through two strategies. Five minutes to install, the rest is just typing."
build:
  list: never
---

[The previous Stele post](/blog/stele-the-memory-layer-i-couldnt-stop-building/) was the "why I built Stele" story. This one is the "okay fine, show me." Walk through. Real commands. Real outputs. Five minutes to install, then we build up the interesting stuff piece by piece.

I'm going to use Claude Code as the agent for this. The same flow works for Codex, Cursor, OpenCode, Gemini CLI, Copilot, and Aider — `stele install --platform <name>` swaps in the right place. Pick whichever you're running.

Quick reality check before we start. Stele exposes its data plane through **two equivalent surfaces**: an MCP server with 18 tools (which the agent calls automatically when it makes sense) and a CLI with the same 18 operations exposed as subcommands (which the agent calls when it'd rather pipe through bash). Same code paths, same JSON shapes. We'll touch both. Most users won't have to think about which is which — the agent picks. But when you're learning, the CLI is the easier surface because you can paste it into a terminal and see what's going on.

Let's go.

## Step 1: install

```bash
pip install stele-core
```

If you want a database other than SQLite, grab the extra:

```bash
pip install 'stele-core[postgres]'
```

After install, you have two binaries on your PATH: `stele` (the CLI, with operator and data-plane subcommands) and `stele-mcp` (the MCP server). Quick sanity check:

```bash
stele --help
```

You should see a tree that starts with `init`, `install`, `doctor`, `status`, `mcp` on the operator side, then `store`, `fetch`, `search`, `query`, `list`, `delete`, `memory`, `extract`, `recall`, `stash` on the data plane. If that's there, you're good.

## Step 2: initialize a project

In whatever directory you want Stele to live in (your project root is the obvious one):

```bash
stele init
```

That writes `.stele/config.yaml` and picks SQLite at `.stele/stele.db` as the default backend. Open the config file if you're curious — it's about twelve lines. The interesting knobs are `backend.type` (memory, sqlite, postgres, mariadb, clickhouse), `pii.raw_fetch_enabled` (off by default — flip it if you trust your environment), `signing.mode` (optional/required for `stele://` reference signatures), and `mcp.stash_threshold_tokens` (when the interception hook should nudge the agent toward stashing big outputs).

Sanity check the config is loadable and the backend is reachable:

```bash
stele doctor
```

You should see something like:

```
stele doctor: ok (.stele/config.yaml) — backend=sqlite capabilities=StashCapabilities(...)
```

If `doctor` exits non-zero, the error message tells you what's wrong. Usually it's a typo in a DSN.

## Step 3: install the agent piece

```bash
stele install --platform claude-code
```

This is the moment where five things happen at once. The output is short but here's what just landed on disk:

- `~/.claude/skills/stele/SKILL.md` — the slash-skill content. When you open Claude Code and type `/stele`, this is what the agent reads.
- `~/.claude/hooks/stele-large-output.sh` — a Bash hook that fires when a tool output exceeds the stash threshold. It doesn't *block* anything. It nudges the agent toward routing the output through `stele_stash_tool_result`.
- `~/.claude/mcp.json` — the MCP server registration. This is the file that tells Claude Code "when you boot, also launch a `stele-mcp` subprocess and connect over stdio."
- `~/.claude/CLAUDE.md` — gets a `## stele` section inserted (or updated, if it already exists). This is the per-user "here's how to use stele" reminder.
- `CLAUDE.md` in your project — same section, project-scoped.

Two things worth knowing about that install. First, `mcp.json` is **merged**, not overwritten. If you already have other MCP servers configured, they survive. (I had to fix that bug while writing this — caught it before shipping. The merge logic has 12 tests now.) Second, the `## stele` section in `CLAUDE.md` is bounded by the marker and the next H2 heading. If you ever want to remove it, `stele uninstall --platform claude-code` strips it cleanly without touching anything else.

Want to confirm it took? Run:

```bash
stele status
```

You'll see a table with one row per platform; the one you installed says `yes` with a version stamp.

## Step 4: restart your agent

Claude Code (and every other AI coding agent I've used) loads its skill list and its MCP servers at startup. Quit and re-open.

After restart, `/stele` appears in the slash-skill list. The MCP server connects on first tool call. If it's not there, see the [troubleshooting section](#troubleshooting) at the bottom.

## Step 5: the first conversation

Paste this into the agent:

> Use stele to:
> 1. Store the text "The team standardized on Postgres 17 in March 2026." as a markdown artifact.
> 2. Add a memory citing that artifact, saying "Project uses Postgres 17."
> 3. Search memory for "Postgres" and tell me what you find.

A working stele install does exactly that, and the response cites a `stele://` reference. Mine looked like this (the IDs will be different on your run):

```
Stored: stele://default/01J7CK9P...
Memory added: 01J7CK9Q... (cites stele://default/01J7CK9P...)
Searched memory for "Postgres": 1 hit.
Hit: "Project uses Postgres 17."
Source: stele://default/01J7CK9P...
```

The interesting thing isn't that the agent *answered.* Plenty of agents answer. The interesting thing is that **the agent's claim is now traceable to an exact artifact that I can fetch and read.** Pull that ref:

```bash
stele fetch stele://default/01J7CK9P...
```

You get back the exact bytes you stored. Not a paraphrase. Not a summary. The original. That's the contract. Every memory has a citation; every citation resolves to bytes.

## Step 6: prove the surfaces are equivalent

The agent did all of step 5 through the MCP. Let's do the same thing through the CLI to prove it's the same code path.

```bash
# Store an artifact
$ stele store --text "Sales VP confirmed Q3 launch on 2026-09-15." --content-type text --pretty
{
  "ref": "stele://default/9f2c8a..."
}

# Add a memory citing it
$ stele memory add "Q3 launch is 2026-09-15" --source-ref stele://default/9f2c8a... --pretty
{
  "memory_id": "abc123...",
  "duplicate_of": null,
  "superseded_ids": []
}

# Search memory
$ stele memory search "launch" --pretty
{
  "hits": [
    {
      "id": "abc123...",
      "text": "Q3 launch is 2026-09-15",
      "source_refs": ["stele://default/9f2c8a..."],
      ...
    }
  ]
}
```

Same JSON shapes as the MCP. Same `bind_handlers` engine under the hood. The agent can use either surface and you'll get the same result. (Worth knowing because it means a non-MCP-capable agent — or a shell script in CI — can do everything an MCP-capable agent can do. Stele doesn't require MCP. It just *prefers* it.)

## Step 7: superseding a fact (the interesting bit)

This is the part of Stele that doesn't exist in mem0 or LangChain memory or the other agent-memory libraries I've looked at. Memories evolve. The world changes. When a fact updates, you don't *edit* the old memory. You replace it with a new one that points at the old one.

Let me show what I mean. Add an initial fact:

```bash
$ stele store --text "Project uses Postgres 15." --content-type text
{"ref": "stele://default/aaa111..."}

$ stele memory add "Database is Postgres 15" --source-ref stele://default/aaa111...
{"memory_id": "mem-old-001", ...}
```

Time passes. The team upgrades. Add the new fact, marking the old one as superseded:

```bash
$ stele store --text "Project upgraded to Postgres 17 in March." --content-type text
{"ref": "stele://default/bbb222..."}

$ stele memory add "Database is Postgres 17" \
    --source-ref stele://default/bbb222... \
    --supersedes mem-old-001
{"memory_id": "mem-new-001", "superseded_ids": ["mem-old-001"], ...}
```

Now search:

```bash
$ stele memory search "database"
```

You only get the new one back by default. The old one isn't deleted — it's just *not the current truth.* You can still query it directly:

```bash
$ stele memory get mem-old-001
{"record": {"id": "mem-old-001", "text": "Database is Postgres 15", "status": "superseded", ...}}
```

Or, the actually interesting query, time-travel:

```bash
$ stele memory search "database" --as-of 2026-03-01T00:00:00Z
```

That returns what memory said about the database *on March 1st* — Postgres 15, because the supersession hadn't happened yet. The history is queryable, not destroyed.

I keep harping on this because it matters. Standard chatbot memory libraries delete old facts when new ones come in. That means:

1. You can't audit *when* the agent learned a wrong thing.
2. You can't replay the agent's reasoning from last week.
3. You can't ever ask "what did I tell the agent on Tuesday" because Tuesday's memory is gone.

Stele treats memory like a ledger. Everything written is permanent (you can soft-delete it but the audit trail survives). Time-travel queries are first-class. If the team finds a bug in 2027 caused by a fact the agent learned in 2026, you can reconstruct the state of the agent's world on the day the bug was introduced. That's not a feature; that's the foundation.

## Step 8: stashing oversized output

Let me show the interception path because it's the one that pays for itself fastest on real workloads.

In the agent, paste:

```
Run: git log --all --pretty=format:"%h %s" | head -200
Then summarize the top three themes in the commit messages.
```

What happens under the hood: the Bash output is around 8,000 tokens. The hook installed at `~/.claude/hooks/stele-large-output.sh` fires, nudging the agent toward stashing. The agent calls `stele_stash_tool_result(tool_name="Bash", raw_output=<the 8k tokens>)`. Stele stores the exact output, generates a one-paragraph summary (via [the `lede` extractive summarizer](https://github.com/yonk-labs/lede) — no LLM, just classical NLP), and returns:

```json
{
  "result": {
    "reference": "stele://default/...",
    "content_type": "log",
    "bytes": 8192,
    "estimated_tokens": 2048,
    "summary": "200 commits across multiple authors, focused on packaging refactor (~40%), bug fixes (~30%), and documentation updates..."
  }
}
```

The agent uses the *summary* (a few hundred tokens) to answer your question. Your context budget didn't get destroyed. If the agent later realizes it needs the raw commits, it calls `stele_fetch(ref)` and pulls them. The full data is on disk; only a pointer crossed the boundary.

You can do the same thing through the CLI when you're scripting:

```bash
$ git log --all --pretty=format:"%h %s" | head -200 | stele stash Bash -
```

The `-` means "read raw_output from stdin." Same engine, same response shape.

I've watched this cut a 30,000-token agent context to 4,000 on a normal session. That's not a benchmark — I owe you a real one — but it's a vibes-check that points the right direction. The bigger the tool output, the bigger the win.

## Step 9: recall (the policy layer)

The last interesting bit is `recall`. The other tools are CRUD — store, fetch, search, add memory, search memory. `recall` is the *strategy* layer. You give it a question and a strategy; it picks the right memories and artifacts and assembles a context.

```bash
$ stele recall "What database version are we using?" --strategy memory_search --pretty
```

You get back:

```json
{
  "response": {
    "strategy_used": "memory_search",
    "context": "Database is Postgres 17",
    "citations": [
      {
        "kind": "memory",
        "id": "mem-new-001",
        "reference": "stele://default/bbb222...",
        "score": 1.0,
        "snippet": "Database is Postgres 17"
      }
    ]
  }
}
```

Strategies:

- `summary_only` — short context, no artifact fetch
- `memory_search` — only memory hits
- `artifact_search` — only artifacts
- `adaptive` — escalates deterministically (memory first, fall through to artifacts if confidence is low)
- `raw_fetch` — pull by ref
- `graph_search` — Phase 5; requires Postgres + pg-raggraph extra
- `abstain` — testing path, refuses to answer

The agent picks the strategy when calling `stele_recall`. You can override via the CLI to experiment. The point of strategies is: don't bury the policy in the agent's prompt. Express it as a name, and your retrieval becomes inspectable and switchable.

## Where to go from here

That's the tour. You've installed Stele, wired it into your agent, stored artifacts, added memories with citations, superseded facts, time-traveled, stashed oversize output, and run recall through two strategies. The whole thing took five minutes to install and the rest was just typing.

A few real places to spend more time:

- **The 18 MCP tools** are documented in [`docs/mcp-tools.md`](https://github.com/yonk-labs/stele/blob/main/docs/mcp-tools.md) on the repo. Every tool has a schema, a default-value list, and a worked example.
- **The CLI** is documented in [`docs/cli-guide.md`](https://github.com/yonk-labs/stele/blob/main/docs/cli-guide.md) with troubleshooting for the most common first-hour failures.
- **The runnable tour**, `examples/mcp_tour.py`, calls every tool against an in-memory Stele and prints the response. It's a sanity check before committing to an agent loop.
- **The living-knowledge layer** (Phase 5) needs Postgres and the `postgres-graph` extra. That's where supersession projects into a graph and `graph_search` becomes a real strategy. [`docs/living-knowledge-setup.md`](https://github.com/yonk-labs/stele/blob/main/docs/living-knowledge-setup.md) has the setup.

## Troubleshooting

**`/stele` isn't in my agent's skill list.** Restart the agent. Skills load at startup. If it's still missing after restart, `stele status` should say `yes` for your platform. If it says `no`, re-run install and check stderr.

**The MCP server fails to launch.** Most common cause: `stele-mcp` isn't on the PATH the agent uses. GUI launchers (Claude Code's .app on macOS, the Windows shortcut) often don't see your shell PATH. Edit `~/.claude/mcp.json` to use an absolute path:

```json
{"mcpServers": {"stele": {"command": "/Users/you/.venv/bin/stele-mcp"}}}
```

**Smoke test the server independently.** This skips the agent entirely:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0"}}}' \
  | timeout 3 stele-mcp
```

A working server prints a JSON-RPC `result` with `serverInfo.name == "stele"`. If you see a traceback instead, the error tells you what's wrong (most often a misconfigured `.stele/config.yaml` or a missing backend extra).

**PII_BLOCKED errors on fetch.** PII scrubbing is on by default for raw artifact bytes. Memory and summary surfaces stay scrubbed regardless. To unblock raw fetch for trusted local use, edit `.stele/config.yaml`:

```yaml
pii:
  raw_fetch_enabled: true
```

Don't do this on a shared deployment.

**Reset everything.**

```bash
stele uninstall --all
rm -rf .stele/
stele init
stele install --platform claude-code
```

That's a clean slate.

## Last thing

I want to know what breaks. The repo is open. The license is Apache 2.0. The bug tracker is empty (for now — I'm sure that's about to change). If you try this and the install fails on a setup I haven't tested, or the agent picks the wrong tool, or the docs don't say something important, file an issue. The whole point of shipping early is that I learn from people who aren't me.

And if it works — if your agent stops bullshitting you about facts it learned last week, or your context budget stops blowing up on huge tool outputs, or you find yourself running `--as-of` queries to debug something the agent thought was true on Tuesday — I'd love to hear about that too.

Go build.
