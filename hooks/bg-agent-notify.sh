#!/bin/bash
# PostToolUse hook: detect completed background agents and report.
# Check /tmp/claude-bg-agents/*.done — if new completion, report + mark reported.
# Runs after every tool call. Lightweight: single ls + grep.

set -euo pipefail

BG_DIR="/tmp/claude-bg-agents"
mkdir -p "$BG_DIR" 2>/dev/null || true

REPORTS=""

for donefile in "$BG_DIR"/*.done; do
  [ -f "$donefile" ] || continue

  BASENAME=$(basename "$donefile" .done)
  TS="$BASENAME"
  REPORTED_FILE="$BG_DIR/${BASENAME}.reported"

  # Skip already reported
  [ -f "$REPORTED_FILE" ] && continue

  EXIT_CODE=$(cat "$donefile" 2>/dev/null || echo "?")

  # Find matching log file for context
  LOG_FILE=""
  TAIL_OUT=""
  for prefix in kimi-run gemini-run; do
    CANDIDATE="/tmp/${prefix}-${TS}.log"
    if [ -f "$CANDIDATE" ]; then
      LOG_FILE="$CANDIDATE"
      TAIL_OUT=$(tail -5 "$CANDIDATE" 2>/dev/null | sed 's/^/  /' || echo "(empty)")
      break
    fi
  done

  # Determine agent type from log path
  AGENT_TYPE="unknown"
  case "$LOG_FILE" in
    *kimi-run*) AGENT_TYPE="kimi-coder" ;;
    *gemini-run*) AGENT_TYPE="gemini" ;;
  esac

  STATUS=$( [ "$EXIT_CODE" = "EXIT=0" ] && echo "OK" || echo "FAIL" )
  ICON=$( [ "$STATUS" = "OK" ] && echo "✓" || echo "✗" )

  REPORTS="${REPORTS}${ICON} [${AGENT_TYPE}] background agent done (${STATUS}, ${EXIT_CODE})
  Log: ${LOG_FILE:-/tmp/${prefix}-run-${TS}.log}
${TAIL_OUT}

"

  # Mark as reported
  touch "$REPORTED_FILE"
done

if [ -n "$REPORTS" ]; then
  # Trim trailing newlines
  REPORTS=$(echo "$REPORTS" | sed '/^$/d')
  cat <<JSON
{
  "decision": "allow",
  "message": "${REPORTS}"
}
JSON
else
  # Output nothing — let it pass silently
  exit 0
fi
