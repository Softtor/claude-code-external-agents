#!/bin/bash
# Install Claude Code external agent dispatch system.
# Adds kimi-coder, gemini-coder, gemini-reviewer as PreToolUse-hooked agents
# with background mode, concurrency limit, and completion notifications.
#
# Usage: bash install.sh [--force]

set -euo pipefail

FORCE=false
[[ "${1:-}" == "--force" ]] && FORCE=true

CLAUDECODE_DIR="${HOME}/.claude"
HOOKS_DIR="${CLAUDECODE_DIR}/hooks"
AGENTS_DIR="${CLAUDECODE_DIR}/agents"
SETTINGS_FILE="${CLAUDECODE_DIR}/settings.json"
SETTINGS_LOCAL="${CLAUDECODE_DIR}/settings.local.json"

echo "==> Claude Code External Agent Dispatch Installer"
echo "    Agents: kimi-coder, gemini-coder, gemini-reviewer"
echo ""

# --- Prerequisites ---
for cmd in jq kimi gemini; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "[WARN]  $cmd not found in PATH — agent using it will fail at runtime"
  else
    echo "[OK]    $cmd: $(command -v $cmd)"
  fi
done
echo ""

# --- Directories ---
mkdir -p "$HOOKS_DIR" "$AGENTS_DIR"
echo "[OK] Directories: $HOOKS_DIR, $AGENTS_DIR"

# --- Hook scripts ---
HOOK_SRC="$(dirname "$0")/hooks/external-agent-intercept.sh"
HOOK_DST="${HOOKS_DIR}/external-agent-intercept.sh"
NOTIFY_SRC="$(dirname "$0")/hooks/bg-agent-notify.sh"
NOTIFY_DST="${HOOKS_DIR}/bg-agent-notify.sh"

if [ -f "$HOOK_DST" ] && [ "$FORCE" != true ]; then
  echo "[SKIP] Intercept hook exists: $HOOK_DST (use --force to overwrite)"
else
  cp "$HOOK_SRC" "$HOOK_DST"
  chmod +x "$HOOK_DST"
  echo "[OK]   Intercept hook: $HOOK_DST"
fi

if [ -f "$NOTIFY_DST" ] && [ "$FORCE" != true ]; then
  echo "[SKIP] Notify hook exists: $NOTIFY_DST (use --force to overwrite)"
else
  cp "$NOTIFY_SRC" "$NOTIFY_DST"
  chmod +x "$NOTIFY_DST"
  echo "[OK]   Notify hook: $NOTIFY_DST"
fi

# --- Agent definitions ---
for agent in kimi-coder gemini-coder gemini-reviewer; do
  AGENT_SRC="$(dirname "$0")/agents/${agent}.md"
  AGENT_DST="${AGENTS_DIR}/${agent}.md"
  if [ -f "$AGENT_DST" ] && [ "$FORCE" != true ]; then
    echo "[SKIP] Agent exists: $AGENT_DST (use --force to overwrite)"
  else
    cp "$AGENT_SRC" "$AGENT_DST"
    echo "[OK]   Agent installed: $AGENT_DST"
  fi
done

# --- Settings hook registration ---
SETTINGS_TO_UPDATE=""
if [ -f "$SETTINGS_LOCAL" ]; then
  SETTINGS_TO_UPDATE="$SETTINGS_LOCAL"
elif [ -f "$SETTINGS_FILE" ]; then
  SETTINGS_TO_UPDATE="$SETTINGS_FILE"
fi

if [ -z "$SETTINGS_TO_UPDATE" ]; then
  echo ""
  echo "[ACTION REQUIRED] No settings.json found. Add this hook manually:"
  echo ""
  echo '  {'
  echo '    "hooks": {'
  echo '      "PreToolUse": [{'
  echo '        "matcher": "Agent",'
  echo '        "hooks": [{'
  echo '          "type": "command",'
  echo '          "command": "bash \"'"$HOOK_DST"'\""'
  echo '        }]'
  echo '      }]'
  echo '    }'
  echo '  }'
  exit 0
fi

# Check if PreToolUse hook already registered
if grep -q "external-agent-intercept" "$SETTINGS_TO_UPDATE" 2>/dev/null; then
  echo "[SKIP] PreToolUse hook already registered in $SETTINGS_TO_UPDATE"
else
  TMP=$(mktemp)
  jq --arg cmd "bash \"$HOOK_DST\"" '
    .hooks.PreToolUse = (.hooks.PreToolUse // []) + [{
      "matcher": "Agent",
      "hooks": [{
        "type": "command",
        "command": $cmd,
        "timeout": 600
      }]
    }]
  ' "$SETTINGS_TO_UPDATE" > "$TMP" && mv "$TMP" "$SETTINGS_TO_UPDATE"
  echo "[OK]   PreToolUse hook registered in $SETTINGS_TO_UPDATE"
fi

# Check if PostToolUse notify hook already registered
if grep -q "bg-agent-notify" "$SETTINGS_TO_UPDATE" 2>/dev/null; then
  echo "[SKIP] PostToolUse notify hook already registered"
else
  TMP=$(mktemp)
  jq --arg cmd "bash \"$NOTIFY_DST\"" '
    .hooks.PostToolUse = (.hooks.PostToolUse // []) + [{
      "matcher": "",
      "hooks": [{
        "type": "command",
        "command": $cmd,
        "timeout": 5
      }]
    }]
  ' "$SETTINGS_TO_UPDATE" > "$TMP" && mv "$TMP" "$SETTINGS_TO_UPDATE"
  echo "[OK]   PostToolUse notify hook registered in $SETTINGS_TO_UPDATE"
fi

# --- Background tracking dir ---
mkdir -p /tmp/claude-bg-agents
echo "[OK]   Background tracking: /tmp/claude-bg-agents/"

echo ""
echo "==> Done. Agents ready:"
echo "    kimi-coder       — kimi CLI for coding tasks"
echo "    gemini-coder     — gemini CLI for coding tasks"
echo "    gemini-reviewer  — gemini CLI for code review"
echo ""
echo "    Foreground: Agent(subagent_type=\"kimi-coder\", prompt=\"...\")"
echo "    Background: Agent(subagent_type=\"kimi-coder\", description=\"task [bg]\", prompt=\"...\")"
echo "    Max 3 concurrent background agents. Completion: /tmp/claude-bg-agents/*.done"
