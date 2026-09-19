#!/bin/bash
# moe-status.sh - Report the state of a query-models-bg.sh run.
# Usage: bash moe-status.sh [--run-id <id> | --latest]
# Exit: 0 = done, 2 = running, 1 = failed or not found

set -euo pipefail

RUNS_DIR="${HOME}/.cache/moe-plugin/runs"
RUN_ID=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --run-id) RUN_ID="$2"; shift 2 ;;
    --latest) RUN_ID=""; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -n "$RUN_ID" ]]; then
  if ! [[ "$RUN_ID" =~ ^[a-zA-Z0-9_-][a-zA-Z0-9._-]*$ ]]; then
    echo "ERROR: Invalid run id '$RUN_ID'" >&2
    exit 1
  fi
  RUN_DIR="$RUNS_DIR/$RUN_ID"
else
  RUN_DIR=$(cat "$RUNS_DIR/latest" 2>/dev/null || true)
fi

if [[ -z "$RUN_DIR" || ! -d "$RUN_DIR" ]]; then
  echo "STATUS=missing"
  echo "ERROR: No run found${RUN_ID:+ for $RUN_ID}" >&2
  exit 1
fi

read_file() { cat "$RUN_DIR/$1" 2>/dev/null || true; }

STATUS=$(read_file status)
PID=$(read_file pid)
PID_ALIVE=false
if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
  PID_ALIVE=true
fi

# Orphan reconciliation: the wrapper can be killed (reboot, OOM, kill -9) after query-models.sh
# finished but before it recorded the outcome, or mid-run. Without this, "running" is forever.
# A missing pid file means the launcher has not written it yet, so that case is left alone.
if [[ "$STATUS" == "running" && -n "$PID" && "$PID_ALIVE" == "false" ]]; then
  SUMMARY=$(read_file summary)
  [[ -z "$SUMMARY" ]] && SUMMARY=$(grep '^SUMMARY:' "$RUN_DIR/stdout.log" 2>/dev/null | tail -1 || true)
  if echo "$SUMMARY" | grep -qE '^SUMMARY: [1-9][0-9]* succeeded'; then
    echo "$SUMMARY" > "$RUN_DIR/summary"
    OUTPUT_DIR=$(read_file output_dir)
    [[ -z "$OUTPUT_DIR" ]] && OUTPUT_DIR=$(sed -n 's/^OUTPUT_DIR=//p' "$RUN_DIR/stdout.log" 2>/dev/null | head -1)
    if [[ -n "$OUTPUT_DIR" && -d "$OUTPUT_DIR" ]] && ! ls "$RUN_DIR/responses/"*.md &>/dev/null; then
      cp "$OUTPUT_DIR"/*.md "$RUN_DIR/responses/" 2>/dev/null || true
    fi
    STATUS="done"
  else
    echo "orphaned: process $PID gone with no successful SUMMARY (killed or crashed mid-run)" > "$RUN_DIR/fail_reason"
    [[ -f "$RUN_DIR/exit_code" ]] || echo "137" > "$RUN_DIR/exit_code"
    STATUS="failed"
  fi
  echo "$STATUS" > "$RUN_DIR/status"
fi

echo "RUN_ID=$(basename "$RUN_DIR")"
echo "RUN_DIR=$RUN_DIR"
echo "STATUS=$STATUS"
echo "PHASE=$(read_file phase)"
echo "STARTED_AT=$(read_file started_at)"
echo "PID=$PID"
echo "PID_ALIVE=$PID_ALIVE"
[[ -s "$RUN_DIR/summary" ]] && echo "$(read_file summary)"
[[ "$STATUS" == "failed" && -s "$RUN_DIR/fail_reason" ]] && echo "FAIL_REASON=$(head -1 "$RUN_DIR/fail_reason")"
echo "RESPONSES_DIR=$RUN_DIR/responses"
for F in "$RUN_DIR/responses/"*.md; do
  [[ -f "$F" ]] && echo "  $F"
done

case "$STATUS" in
  done) exit 0 ;;
  running) exit 2 ;;
  *) exit 1 ;;
esac
