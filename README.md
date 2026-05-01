# Claude Code External Agent Dispatch

Install script for dispatching kimi, gemini, and other external CLI AI agents as Claude Code subagents — with zero LLM quota cost for dispatch.

## What This Does

Normally `Agent()` tool calls consume Claude Code LLM quota. This system instead intercepts `Agent()` calls for specific subagent types and runs the real external CLI binary directly, returning output through the hook's deny reason.

**Agents included:**

| Agent | CLI | Use Case |
|-------|-----|----------|
| `kimi-coder` | `kimi` | Well-scoped coding tasks with exact file/line specs |
| `gemini-coder` | `gemini` | Coding tasks, visual analysis via screenshots |
| `gemini-reviewer` | `gemini` | Diff/branch/PR review with visual capability |

## Features

- **Zero quota dispatch** — hook intercepts before LLM is called
- **Foreground mode** — blocks until done, returns output inline
- **Background mode** (`[bg]`) — spawns and returns immediately with PID
- **Concurrency limit** — max 3 simultaneous background agents
- **Completion notifications** — `notify-send` desktop notification on finish
- **Completion tracking** — `/tmp/claude-bg-agents/{ts}.done` with exit code
- **Auto cleanup** — stale tracking files and logs (>24h) cleaned on each invocation

## Install

```bash
git clone https://github.com/Softtor/claude-code-external-agents.git /tmp/claude-code-external-agents
cd /tmp/claude-code-external-agents
bash install.sh
```

With overwrite:

```bash
bash install.sh --force
```

### Prerequisites

- `jq` — JSON processor
- `kimi` — [kimi-cli](https://github.com/Moonshot-AI/kimi-cli) (for kimi-coder agent)
- `gemini` — [gemini-cli](https://github.com/anthropics/gemini-cli) (for gemini-coder/gemini-reviewer agents)
- Claude Code — the host environment

Missing CLIs won't block install, but the corresponding agent will fail at runtime.

## What Gets Installed

```
~/.claude/
  hooks/external-agent-intercept.sh   — PreToolUse hook script
  agents/kimi-coder.md                — kimi-coder agent definition
  agents/gemini-coder.md              — gemini-coder agent definition
  agents/gemini-reviewer.md           — gemini-reviewer agent definition
  settings.json (or settings.local.json) — hook registration added
```

## Usage

### Foreground (blocking)

```
Agent(subagent_type="kimi-coder", prompt="fix the login bug in auth.ts")
```

Returns output inline after completion.

### Background (non-blocking)

```
Agent(subagent_type="kimi-coder", description="fix tests [bg]", prompt="fix all failing tests")
```

Returns immediately with PID and tracking info:

```
[kimi-coder] BACKGROUND dispatched.

PID:       1812155 (watcher: 1812156)
Active:    1/3 (1812155)
Task:      /tmp/kimi-task-1777654657.md
Log:       /tmp/kimi-run-1777654657.log
Done:      /tmp/claude-bg-agents/1777654657.done
```

### Track Completion

```bash
# Poll for .done file
until [ -f /tmp/claude-bg-agents/1777654657.done ]; do sleep 2; done
cat /tmp/claude-bg-agents/1777654657.done  # EXIT=0
```

Or via Claude Code Monitor tool:

```
Monitor(command="tail -f /tmp/kimi-run-1777654657.log", description="kimi-coder PID 1812155")
```

### Concurrency

Max 3 background agents. 4th dispatch returns:

```
[kimi-coder] BLOCKED: max 3 background agents (3 running: 1813230 1813231 1813232).
Wait for one to finish (check /tmp/claude-bg-agents/*.done) then retry.
```

## Files

```
~/.claude/
├── hooks/external-agent-intercept.sh    # hook script
├── agents/
│   ├── kimi-coder.md
│   ├── gemini-coder.md
│   └── gemini-reviewer.md
└── settings.json                        # hook registration

/tmp/claude-bg-agents/                   # runtime tracking
  ├── {ts}.pid                           # active process
  └── {ts}.done                          # completion (EXIT=N)

/tmp/kimi-task-{ts}.md                   # task prompt
/tmp/kimi-run-{ts}.log                   # output log
/tmp/gemini-task-{ts}.md
/tmp/gemini-run-{ts}.log
```

## How It Works

1. `Agent(subagent_type="kimi-coder", ...)` is intercepted by PreToolUse hook
2. `external-agent-intercept.sh` checks subagent_type — only kimi-coder/gemini-coder/gemini-reviewer are intercepted; all others pass through
3. Prompt is written to timestamped task file
4. Real CLI binary runs (kimi or gemini)
5. Output is returned in hook's `deny` reason — Claude Code displays it
6. Background mode: watcher process polls for completion, writes `.done`, fires desktop notification
