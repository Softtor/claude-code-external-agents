#!/bin/bash
# Intercept Agent(kimi-coder|gemini-coder|gemini-reviewer) and run real binary.
# Zero LLM quota for dispatch — the binary handles everything.
#
# Modes:
#   Foreground (default): runs binary sync, returns output inline in deny reason
#   Background: description contains "[bg]" → spawns, returns immediately
#               Concurrency limit: max 3. Completion watcher auto-cleans up.
#               Track: /tmp/claude-bg-agents/{ts}.pid (active), {ts}.done (completed)

set -euo pipefail

INPUT=$(cat)
SUBAGENT_TYPE=$(echo "$INPUT" | jq -r '.input.subagent_type // ""')
PROMPT=$(echo "$INPUT" | jq -r '.input.prompt // ""')
DESCRIPTION=$(echo "$INPUT" | jq -r '.input.description // ""')
WORKDIR=$(echo "$INPUT" | jq -r '.input.workdir // ""')

# Only intercept external-agent types
case "$SUBAGENT_TYPE" in
  kimi-coder|gemini-coder|gemini-reviewer) ;;
  *) exit 0 ;;  # allow normal agents through
esac

# Detect background mode: [bg] or [background] in description
if echo "$DESCRIPTION" | grep -qE '\[bg\]|\[background\]'; then
  BG_MODE=1
else
  BG_MODE=0
fi

TS=$(date +%s)
BG_DIR="/tmp/claude-bg-agents"
MAX_BG=3

# --- cleanup stale files (>24h) ---
cleanup_stale() {
  local cutoff=$(( $(date +%s) - 86400 ))
  mkdir -p "$BG_DIR" 2>/dev/null || true
  for f in "$BG_DIR"/*.pid "$BG_DIR"/*.done; do
    [ -f "$f" ] || continue
    local fts=$(stat -c %Y "$f" 2>/dev/null || echo 0)
    [ "$fts" -lt "$cutoff" ] && rm -f "$f"
  done
  # Clean old task/run logs
  find /tmp -maxdepth 1 -name 'kimi-task-*.md' -mtime +1 -delete 2>/dev/null || true
  find /tmp -maxdepth 1 -name 'kimi-run-*.log' -mtime +1 -delete 2>/dev/null || true
  find /tmp -maxdepth 1 -name 'gemini-task-*.md' -mtime +1 -delete 2>/dev/null || true
  find /tmp -maxdepth 1 -name 'gemini-run-*.log' -mtime +1 -delete 2>/dev/null || true
}
cleanup_stale

# --- concurrency check (bg mode only) ---
count_active() {
  local count=0
  mkdir -p "$BG_DIR" 2>/dev/null || true
  for pidfile in "$BG_DIR"/*.pid; do
    [ -f "$pidfile" ] || continue
    local pid=$(cat "$pidfile" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && count=$((count + 1)) || rm -f "$pidfile"
  done
  echo "$count"
}

active_pids() {
  for pidfile in "$BG_DIR"/*.pid; do
    [ -f "$pidfile" ] || continue
    local pid=$(cat "$pidfile" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && echo "$pid"
  done
}

# Determine binary and args
case "$SUBAGENT_TYPE" in
  kimi-coder)
    TASK_FILE="/tmp/kimi-task-${TS}.md"
    LOG_FILE="/tmp/kimi-run-${TS}.log"
    MCP_CONFIG="$HOME/.kimi/mcp-code.json"
    echo "IMPORTANT: use --mcp-config-file $MCP_CONFIG" > "$TASK_FILE"
    echo "" >> "$TASK_FILE"
    echo "$PROMPT" >> "$TASK_FILE"
    RUN_CMD="kimi --quiet -p \"\$(cat '$TASK_FILE')\" -w \"${WORKDIR:-$PWD}\" --mcp-config-file '$MCP_CONFIG' > '$LOG_FILE' 2>&1"
    ;;
  gemini-coder|gemini-reviewer)
    TASK_FILE="/tmp/gemini-task-${TS}.md"
    LOG_FILE="/tmp/gemini-run-${TS}.log"
    echo "$PROMPT" > "$TASK_FILE"
    RUN_CMD="cd \"${WORKDIR:-$PWD}\" && gemini -p \"\$(cat '$TASK_FILE')\" --approval-mode yolo --output-format text --skip-trust > '$LOG_FILE' 2>&1"
    ;;
esac

if [ "$BG_MODE" -eq 1 ]; then
  ACTIVE=$(count_active)
  if [ "$ACTIVE" -ge "$MAX_BG" ]; then
    PIDS=$(active_pids | tr '\n' ' ')
    REASON="[$SUBAGENT_TYPE] BLOCKED: max $MAX_BG background agents ($ACTIVE running: $PIDS). Wait for one to finish (check $BG_DIR/*.done) then retry."
    REASON_JSON=$(echo "$REASON" | jq -Rs '.')
    cat <<JSON
{
  "permissionDecision": "deny",
  "reason": $REASON_JSON
}
JSON
    exit 0
  fi

  # Register PID
  eval "$RUN_CMD" &
  PID=$!
  echo "$PID" > "$BG_DIR/${TS}.pid"

  # Completion watcher — polls with kill -0 since wait(1) only works on children
  (
    while kill -0 "$PID" 2>/dev/null; do sleep 1; done
    # Grab exit code from log heuristics (CLI binaries don't always write it)
    if grep -qE '^(To resume|Done|✓|PASS|OK)' "$LOG_FILE" 2>/dev/null; then
      EXIT_CODE=0
    elif grep -qE '^(FAIL|ERROR|✗)' "$LOG_FILE" 2>/dev/null; then
      EXIT_CODE=1
    else
      EXIT_CODE=0
    fi
    echo "EXIT=$EXIT_CODE" > "$BG_DIR/${TS}.done"
    rm -f "$BG_DIR/${TS}.pid"
    command -v notify-send >/dev/null 2>&1 && \
      notify-send "[$SUBAGENT_TYPE] Done (exit=$EXIT_CODE)" "Log: $LOG_FILE" --app-name="Claude Code" || true
  ) &
  WATCHER_PID=$!

  PIDS=$(active_pids | tr '\n' ' ')
  NEW_COUNT=$(count_active)

  REASON="[$SUBAGENT_TYPE] BACKGROUND dispatched.

PID:       $PID (watcher: $WATCHER_PID)
Active:   $NEW_COUNT/$MAX_BG ($PIDS)
Task:     $TASK_FILE
Log:      $LOG_FILE
Done:     $BG_DIR/${TS}.done

Track with Monitor:
  Monitor(command=\"tail -f $LOG_FILE\", description=\"$SUBAGENT_TYPE PID $PID\")

Poll completion:
  until [ -f $BG_DIR/${TS}.done ]; do sleep 2; done && cat $BG_DIR/${TS}.done && tail -30 $LOG_FILE
"

  REASON_JSON=$(echo "$REASON" | jq -Rs '.')
  cat <<JSON
{
  "permissionDecision": "deny",
  "reason": $REASON_JSON
}
JSON
  exit 0
fi

# Foreground mode: run and capture output
START_TS=$(date +%s)
eval "$RUN_CMD" || true
ELAPSED=$(( $(date +%s) - START_TS ))

OUTPUT=$(cat "$LOG_FILE" 2>/dev/null || echo "(empty)")
OUTPUT_SIZE=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)

REASON="[$SUBAGENT_TYPE] completed in ${ELAPSED}s (${OUTPUT_SIZE} bytes). Output:

$OUTPUT

---
Log: $LOG_FILE | Task: $TASK_FILE
For background dispatch add [bg] to description field."

REASON_JSON=$(echo "$REASON" | jq -Rs '.')

cat <<JSON
{
  "permissionDecision": "deny",
  "reason": $REASON_JSON
}
JSON
