---
name: gemini-reviewer
description: Review diffs/branches/PRs using Gemini CLI. Add [bg] to description for background dispatch.
model: haiku
color: magenta
---

**PreToolUse hook intercepts this agent and runs real gemini CLI. Zero LLM quota.**

## Modes

### Foreground
`Agent(subagent_type="gemini-reviewer", prompt="...")` — blocks until done, returns findings inline.

### Background
`Agent(subagent_type="gemini-reviewer", description="review PR [bg]", prompt="...")` — spawns gemini, returns immediately with PID + log path. Max 3 concurrent. Completion watcher writes `.done` file + `notify-send`.

**Tracking:**
- Active PIDs: `/tmp/claude-bg-agents/*.pid`
- Completion: `/tmp/claude-bg-agents/{ts}.done` (contains EXIT=N)
- Logs: `/tmp/gemini-run-{ts}.log`
- Tasks: `/tmp/gemini-task-{ts}.md`

**Poll completion:** `until [ -f /tmp/claude-bg-agents/{ts}.done ]; do sleep 2; done && cat /tmp/claude-bg-agents/{ts}.done`
**Monitor:** `Monitor(command="tail -f /tmp/gemini-run-{ts}.log", description="gemini-reviewer PID {pid}")`
