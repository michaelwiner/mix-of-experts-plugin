#!/bin/bash
# query-models-bg.sh - Run query-models.sh as a detached background job and return immediately.
# Usage: bash query-models-bg.sh --settings-file <path> --phase <phase> --prompt-file <path>
#                                [--no-cache] [--models a,b] [--confirm-cost] [--run-id <id>]
# Exit: 0 = launched, 1 = error, 3 = estimated cost above max_cost_usd (ask, then --confirm-cost)
# Poll with: bash moe-status.sh --run-id <id>   (or --latest)
#
# Why detached: a fan-out takes minutes, and agent hosts (Cursor in particular) kill the
# foreground process group when a turn is interrupted. The job runs in its own session and
# writes everything to RUN_DIR, so the agent can come back and read it later.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

if ! command -v python3 &>/dev/null; then
  echo "ERROR: python3 is required to detach background jobs. Use query-models.sh in the foreground instead." >&2
  exit 1
fi

SETTINGS_FILE=""
PHASE=""
PROMPT_FILE=""
NO_CACHE=false
MODELS_OVERRIDE=""
CONFIRM_COST=false
RUN_ID=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --settings-file) SETTINGS_FILE="$2"; shift 2 ;;
    --phase) PHASE="$2"; shift 2 ;;
    --prompt-file) PROMPT_FILE="$2"; shift 2 ;;
    --no-cache) NO_CACHE=true; shift ;;
    --models) MODELS_OVERRIDE="$2"; shift 2 ;;
    --confirm-cost) CONFIRM_COST=true; shift ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$SETTINGS_FILE" || -z "$PHASE" || -z "$PROMPT_FILE" ]]; then
  echo "Usage: bash query-models-bg.sh --settings-file <path> --phase <phase> --prompt-file <path> [--no-cache] [--models a,b] [--confirm-cost] [--run-id <id>]" >&2
  exit 1
fi

if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "ERROR: Prompt file not found: $PROMPT_FILE" >&2
  exit 1
fi

# Settings and cost are checked synchronously: the caller must see a bad setting or the cost
# gate now, not discover it later as a failed background run.
PREFLIGHT_ARGS=(--settings-file "$SETTINGS_FILE" --phase "$PHASE" --prompt-file "$PROMPT_FILE" --estimate-only)
[[ -n "$MODELS_OVERRIDE" ]] && PREFLIGHT_ARGS+=(--models "$MODELS_OVERRIDE")
[[ "$NO_CACHE" == "true" ]] && PREFLIGHT_ARGS+=(--no-cache)
[[ "$CONFIRM_COST" == "true" ]] && PREFLIGHT_ARGS+=(--confirm-cost)
PREFLIGHT_RC=0
PREFLIGHT_OUT=$(bash "$SCRIPT_DIR/query-models.sh" "${PREFLIGHT_ARGS[@]}" 2>&1) || PREFLIGHT_RC=$?
if [[ $PREFLIGHT_RC -ne 0 ]]; then
  echo "$PREFLIGHT_OUT" >&2
  exit "$PREFLIGHT_RC"
fi
echo "$PREFLIGHT_OUT" | grep -E '^Estimated max cost' || true

[[ -z "$RUN_ID" ]] && RUN_ID="$(date +%Y%m%d-%H%M%S)-${PHASE}-$$"
if ! [[ "$RUN_ID" =~ ^[a-zA-Z0-9_-][a-zA-Z0-9._-]*$ ]]; then
  echo "ERROR: Invalid run id '$RUN_ID'. Use letters, digits, '.', '_' or '-'" >&2
  exit 1
fi

RUNS_DIR="${HOME}/.cache/moe-plugin/runs"
RUN_DIR="$RUNS_DIR/$RUN_ID"
if [[ -e "$RUN_DIR" ]]; then
  echo "ERROR: Run directory already exists: $RUN_DIR" >&2
  exit 1
fi
mkdir -p "$RUN_DIR/responses"
chmod 700 "${HOME}/.cache/moe-plugin" "$RUNS_DIR" "$RUN_DIR"

# Snapshot the prompt: callers usually write it to a temp file they may delete before the job ends.
cp "$PROMPT_FILE" "$RUN_DIR/prompt.md"
if [[ "$SETTINGS_FILE" != /* && -f "$SETTINGS_FILE" ]]; then
  SETTINGS_FILE="$(cd "$(dirname "$SETTINGS_FILE")" && pwd -P)/$(basename "$SETTINGS_FILE")"
fi

echo "$PHASE" > "$RUN_DIR/phase"
date -u +%Y-%m-%dT%H:%M:%SZ > "$RUN_DIR/started_at"
# Written before launch so a fast job can never be overwritten back to "running".
echo "running" > "$RUN_DIR/status"

QUERY_ARGS=(--settings-file "$SETTINGS_FILE" --phase "$PHASE" --prompt-file "$RUN_DIR/prompt.md")
[[ -n "$MODELS_OVERRIDE" ]] && QUERY_ARGS+=(--models "$MODELS_OVERRIDE")
[[ "$NO_CACHE" == "true" ]] && QUERY_ARGS+=(--no-cache)
# The preflight already applied the gate; the detached run must not stop on it again.
QUERY_ARGS+=(--confirm-cost)

{
  echo '#!/bin/bash'
  echo "RUN_DIR=$(printf '%q' "$RUN_DIR")"
  printf 'bash %q' "$SCRIPT_DIR/query-models.sh"
  printf ' %q' "${QUERY_ARGS[@]}"
  echo ' > "$RUN_DIR/stdout.log" 2>&1'
  cat <<'WRAPPER'
EXIT_CODE=$?
echo "$EXIT_CODE" > "$RUN_DIR/exit_code"

OUTPUT_DIR=$(sed -n 's/^OUTPUT_DIR=//p' "$RUN_DIR/stdout.log" | head -1)
if [[ -n "$OUTPUT_DIR" && -d "$OUTPUT_DIR" ]]; then
  echo "$OUTPUT_DIR" > "$RUN_DIR/output_dir"
  cp "$OUTPUT_DIR"/*.md "$RUN_DIR/responses/" 2>/dev/null
fi

grep '^SUMMARY:' "$RUN_DIR/stdout.log" | tail -1 > "$RUN_DIR/summary"

# "done" means at least one expert answered; a clean exit with zero answers is still a failure.
if grep -qE '^SUMMARY: [1-9][0-9]* succeeded' "$RUN_DIR/summary"; then
  echo "done" > "$RUN_DIR/status"
else
  if [[ -s "$RUN_DIR/summary" ]]; then
    cat "$RUN_DIR/summary" > "$RUN_DIR/fail_reason"
  else
    { echo "query-models.sh exited $EXIT_CODE with no SUMMARY. Last log lines:"; tail -5 "$RUN_DIR/stdout.log"; } > "$RUN_DIR/fail_reason"
  fi
  echo "failed" > "$RUN_DIR/status"
fi
WRAPPER
} > "$RUN_DIR/run.sh"
chmod 700 "$RUN_DIR/run.sh"

cat > "$RUN_DIR/launch.py" <<'PY'
import os, subprocess, sys
run_dir = sys.argv[1]
proc = subprocess.Popen(
    ["bash", os.path.join(run_dir, "run.sh")],
    stdin=subprocess.DEVNULL,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    start_new_session=True,
    close_fds=True,
)
with open(os.path.join(run_dir, "pid"), "w") as f:
    f.write(f"{proc.pid}\n")
print(proc.pid)
PY

# If the launcher itself fails there is no pid for moe-status to reconcile, so record it here.
if ! PID=$(python3 "$RUN_DIR/launch.py" "$RUN_DIR"); then
  echo "launch failed: python3 could not start the detached job" > "$RUN_DIR/fail_reason"
  echo "failed" > "$RUN_DIR/status"
  echo "ERROR: Failed to launch background job. See $RUN_DIR/fail_reason" >&2
  exit 1
fi

# "latest" is a plain file for tools that cannot follow symlinks; latest-link is for humans.
# Both are best-effort: the job is already running, and concurrent launches racing on these
# pointers must never make this script exit before it prints the RUN_ID.
echo "$RUN_DIR" > "$RUNS_DIR/.latest.$$" && mv -f "$RUNS_DIR/.latest.$$" "$RUNS_DIR/latest" || true
ln -sfn "$RUN_DIR" "$RUNS_DIR/latest-link" 2>/dev/null || true

echo "RUN_ID=$RUN_ID"
echo "RUN_DIR=$RUN_DIR"
echo "PID=$PID"
echo "Poll: bash $SCRIPT_DIR/moe-status.sh --run-id $RUN_ID   (exit 0 = done, 2 = running, 1 = failed)"
