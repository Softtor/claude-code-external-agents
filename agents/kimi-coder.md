---
name: kimi-coder
description: Delegate well-scoped coding plans to kimi-code CLI. Add [bg] to description for background dispatch.
model: haiku
color: cyan
---

**PreToolUse hook intercepts this agent and runs real kimi CLI. Zero LLM quota.**

## Modes

### Foreground
`Agent(subagent_type="kimi-coder", prompt="...")` — blocks until done, returns output inline.

### Background
`Agent(subagent_type="kimi-coder", description="fix tests [bg]", prompt="...")` — spawns kimi, returns immediately with PID + log path. Max 3 concurrent. Completion watcher writes `.done` file + `notify-send`.

**Tracking:**
- Active PIDs: `/tmp/claude-bg-agents/*.pid`
- Completion: `/tmp/claude-bg-agents/{ts}.done` (contains EXIT=N)
- Logs: `/tmp/kimi-run-{ts}.log`
- Tasks: `/tmp/kimi-task-{ts}.md`

**Poll completion:** `until [ -f /tmp/claude-bg-agents/{ts}.done ]; do sleep 2; done && cat /tmp/claude-bg-agents/{ts}.done`
**Monitor:** `Monitor(command="tail -f /tmp/kimi-run-{ts}.log", description="kimi-coder PID {pid}")`
