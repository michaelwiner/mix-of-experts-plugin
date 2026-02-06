#!/bin/bash
# query-models.sh - Fan out a prompt to multiple AI models via OpenRouter
# Usage: bash query-models.sh --settings-file <path> --phase <phase> --prompt-file <path> [--no-cache]

set -euo pipefail

# ── Dependency checks ──────────────────────────────────────────────
for cmd in curl jq bc; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: Required dependency '$cmd' is not installed." >&2
    echo "  Install with: brew install $cmd" >&2
    exit 1
  fi
done

# ── Parse arguments ────────────────────────────────────────────────
SETTINGS_FILE=""
PHASE=""
PROMPT_FILE=""
NO_CACHE=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --settings-file) SETTINGS_FILE="$2"; shift 2 ;;
    --phase) PHASE="$2"; shift 2 ;;
    --prompt-file) PROMPT_FILE="$2"; shift 2 ;;
    --no-cache) NO_CACHE=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Validate required arguments
if [[ -z "$SETTINGS_FILE" || -z "$PHASE" || -z "$PROMPT_FILE" ]]; then
  echo "Usage: bash query-models.sh --settings-file <path> --phase <phase> --prompt-file <path> [--no-cache]" >&2
  echo "  --settings-file  Path to .local.md settings file with YAML frontmatter" >&2
  echo "  --phase          Consultation phase: architecture, review, or ad-hoc" >&2
  echo "  --prompt-file    Path to file containing the prompt to send" >&2
  echo "  --no-cache       Skip cache, force fresh API calls" >&2
  exit 1
fi

if [[ ! -f "$SETTINGS_FILE" ]]; then
  echo "ERROR: Settings file not found: $SETTINGS_FILE" >&2
  echo "Create it with your OpenRouter API key. See the plugin README for format." >&2
  exit 1
fi

if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "ERROR: Prompt file not found: $PROMPT_FILE" >&2
  exit 1
fi

# ── Parse settings from YAML frontmatter ───────────────────────────
FRONTMATTER=$(sed -n '/^---$/,/^---$/p' "$SETTINGS_FILE" | sed '1d;$d')

if [[ -z "$FRONTMATTER" ]]; then
  echo "ERROR: No YAML frontmatter found in settings file." >&2
  echo "The file must start and end with --- delimiters." >&2
  exit 1
fi

# Extract API key
API_KEY=$(echo "$FRONTMATTER" | grep '^openrouter_api_key:' | sed 's/^openrouter_api_key: *//' | tr -d '"' | tr -d "'")
if [[ -z "$API_KEY" ]]; then
  echo "ERROR: openrouter_api_key not found in settings file" >&2
  exit 1
fi

# Validate API key format
if [[ ! "$API_KEY" =~ ^sk-or- ]]; then
  echo "WARNING: API key does not start with 'sk-or-'. It may be invalid." >&2
fi

# Extract models list (comma-separated in settings)
MODELS_RAW=$(echo "$FRONTMATTER" | grep '^models:' | sed 's/^models: *//' || true)
if [[ -z "$MODELS_RAW" ]]; then
  MODELS_RAW="openai/gpt-5.2,google/gemini-3-flash-preview,deepseek/deepseek-v3.2-20251201"
fi

# Extract optional fields (|| true prevents set -e from killing on no match)
MAX_TOKENS=$(echo "$FRONTMATTER" | grep '^max_tokens:' | sed 's/^max_tokens: *//' || true)
[[ -z "$MAX_TOKENS" ]] && MAX_TOKENS=8192

TEMPERATURE=$(echo "$FRONTMATTER" | grep '^temperature:' | sed 's/^temperature: *//' || true)
[[ -z "$TEMPERATURE" ]] && TEMPERATURE=0.3

TIMEOUT=$(echo "$FRONTMATTER" | grep '^timeout:' | sed 's/^timeout: *//' || true)
[[ -z "$TIMEOUT" ]] && TIMEOUT=300

MAX_RETRIES=$(echo "$FRONTMATTER" | grep '^retries:' | sed 's/^retries: *//' || true)
[[ -z "$MAX_RETRIES" ]] && MAX_RETRIES=2

FALLBACKS_RAW=$(echo "$FRONTMATTER" | grep '^fallback_models:' | sed 's/^fallback_models: *//' || true)

# ── Validate settings ─────────────────────────────────────────────
validate_positive_int() {
  local NAME="$1" VALUE="$2"
  if ! [[ "$VALUE" =~ ^[0-9]+$ ]] || [[ "$VALUE" -le 0 ]]; then
    echo "ERROR: $NAME must be a positive integer, got '$VALUE'" >&2
    exit 1
  fi
}

validate_non_negative_int() {
  local NAME="$1" VALUE="$2"
  if ! [[ "$VALUE" =~ ^[0-9]+$ ]]; then
    echo "ERROR: $NAME must be a non-negative integer, got '$VALUE'" >&2
    exit 1
  fi
}

validate_temperature() {
  local VALUE="$1"
  if ! [[ "$VALUE" =~ ^[0-9]+\.?[0-9]*$ ]]; then
    echo "ERROR: temperature must be a number between 0.0 and 2.0, got '$VALUE'" >&2
    exit 1
  fi
  if [[ $(echo "$VALUE > 2" | bc -l) -eq 1 ]]; then
    echo "ERROR: temperature must be between 0.0 and 2.0, got '$VALUE'" >&2
    exit 1
  fi
}

validate_model_name() {
  local MODEL
  MODEL=$(echo "$1" | tr -d ' ')
  if ! [[ "$MODEL" =~ ^[a-zA-Z0-9_-]+/[a-zA-Z0-9._-]+$ ]]; then
    echo "ERROR: Invalid model name: '$MODEL'. Expected format: provider/model-name" >&2
    exit 1
  fi
}

validate_positive_int "max_tokens" "$MAX_TOKENS"
validate_temperature "$TEMPERATURE"
validate_positive_int "timeout" "$TIMEOUT"
validate_non_negative_int "retries" "$MAX_RETRIES"

IFS=',' read -ra _VALIDATE_MODELS <<< "$MODELS_RAW"
for _VM in "${_VALIDATE_MODELS[@]}"; do
  validate_model_name "$_VM"
done

if [[ -n "$FALLBACKS_RAW" ]]; then
  IFS=',' read -ra _VALIDATE_FALLBACKS <<< "$FALLBACKS_RAW"
  for _VF in "${_VALIDATE_FALLBACKS[@]}"; do
    validate_model_name "$_VF"
  done
fi

# Read prompt
PROMPT=$(cat "$PROMPT_FILE")

if [[ -z "$PROMPT" ]]; then
  echo "ERROR: Prompt file is empty: $PROMPT_FILE" >&2
  exit 1
fi

# ── Cache setup ────────────────────────────────────────────────────
CACHE_DIR="${HOME}/.cache/moe-plugin"
mkdir -p "$CACHE_DIR"
chmod 700 "$CACHE_DIR"

PROMPT_HASH=$(shasum -a 256 "$PROMPT_FILE" 2>/dev/null | cut -d' ' -f1 || md5 -q "$PROMPT_FILE" 2>/dev/null || echo "nohash")

cache_key() {
  local MODEL="$1"
  echo -n "${PHASE}|${MODEL}|${TEMPERATURE}|${MAX_TOKENS}|${PROMPT_HASH}" | shasum -a 256 2>/dev/null | cut -d' ' -f1 || \
    echo -n "${PHASE}|${MODEL}|${TEMPERATURE}|${MAX_TOKENS}|${PROMPT_HASH}" | md5 2>/dev/null
}

# ── Create output directory ────────────────────────────────────────
OUTPUT_DIR=$(mktemp -d)

# Track temp files for cleanup on exit/signal
_MOE_TEMP_FILES=()

_moe_cleanup() {
  for f in "${_MOE_TEMP_FILES[@]}"; do
    rm -f "$f" 2>/dev/null
  done
  rm -f "$OUTPUT_DIR"/*.status "$OUTPUT_DIR"/*.gen-id 2>/dev/null
}

trap _moe_cleanup EXIT INT TERM

echo "OUTPUT_DIR=$OUTPUT_DIR"

# Split models into array
IFS=',' read -ra MODELS <<< "$MODELS_RAW"

# Split fallback models if provided
FALLBACKS=()
if [[ -n "$FALLBACKS_RAW" ]]; then
  IFS=',' read -ra FALLBACKS <<< "$FALLBACKS_RAW"
fi

# ── System prompt based on phase ───────────────────────────────────
case $PHASE in
  architecture)
    SYSTEM_PROMPT="You are a senior software architect. Analyze the requirements and codebase context provided, then propose a detailed implementation architecture. Structure your response with these exact sections:

## Summary
A 2-3 sentence overview of your proposed approach.

## Key Claims
A numbered list of your core architectural recommendations. Each claim should be a concrete, specific position (e.g. '1. Use an event-driven architecture with a central message bus' not '1. Consider the architecture carefully').

## Implementation Detail
File structure, key components, data flow, and concrete implementation guidance. Include code snippets where helpful.

## Risks and Trade-offs
What could go wrong with this approach. What you are trading away. Be honest about weaknesses.

## Confidence
State HIGH, MEDIUM, or LOW confidence in this proposal, with a one-sentence justification.

Be specific and opinionated. Every section is required.

IMPORTANT: Your response is limited to ${MAX_TOKENS} tokens. Be concise and prioritize the most valuable insights."
    ;;
  review)
    SYSTEM_PROMPT="You are a senior code reviewer. Review the code changes provided for bugs, security vulnerabilities, performance concerns, code quality, and adherence to conventions. Structure your response with these exact sections:

## Summary
A 2-3 sentence overall assessment of the code quality.

## Critical Issues
Issues that must be fixed before merging — bugs, security vulnerabilities, data loss risks. Format each as: **[title]** (file:line) — description. Write 'None identified.' if empty.

## Warnings
Issues that should be addressed but are not blocking — performance concerns, code smells, potential edge cases. Same format. Write 'None identified.' if empty.

## Suggestions
Nice-to-have improvements — style, readability, minor refactors. Same format. Write 'None identified.' if empty.

## Confidence
State HIGH, MEDIUM, or LOW confidence in this review, with a one-sentence justification (e.g. 'MEDIUM — I lack full context on the authentication module').

Be thorough but fair. Every section is required.

IMPORTANT: Your response is limited to ${MAX_TOKENS} tokens. Be concise and prioritize the most valuable insights."
    ;;
  ad-hoc)
    SYSTEM_PROMPT="You are a senior software engineer providing expert consultation. Analyze the question or problem provided and give a thorough, well-reasoned response. Structure your response with these exact sections:

## Summary
A 2-3 sentence direct answer to the question.

## Analysis
Detailed reasoning, evidence, and code examples supporting your answer.

## Alternatives Considered
Other approaches you considered and why you prefer your recommendation.

## Confidence
State HIGH, MEDIUM, or LOW confidence in this response, with a one-sentence justification.

Be specific. Every section is required.

IMPORTANT: Your response is limited to ${MAX_TOKENS} tokens. Be concise and prioritize the most valuable insights."
    ;;
  *)
    SYSTEM_PROMPT="You are a senior software engineer. Begin with a 2-3 sentence summary, then provide detailed analysis. Be specific and include code examples where helpful.

IMPORTANT: Your response is limited to ${MAX_TOKENS} tokens. Be concise and prioritize the most valuable insights."
    ;;
esac

# ── Pre-flight cost estimation ────────────────────────────────────
_PROMPT_CHARS=$(wc -c < "$PROMPT_FILE" | tr -d ' ')
_SYSTEM_CHARS=${#SYSTEM_PROMPT}
_EST_PROMPT_TOKENS=$(( (_PROMPT_CHARS + _SYSTEM_CHARS) / 4 ))
IFS=',' read -ra _EST_MODELS <<< "$MODELS_RAW"
_NUM_MODELS=${#_EST_MODELS[@]}
echo "Estimated: ~${_EST_PROMPT_TOKENS} prompt tokens x ${_NUM_MODELS} models | Max completion: ${MAX_TOKENS} tokens/model" >&2

# ── API call function with retries ─────────────────────────────────
call_model() {
  local MODEL="$1"
  local OUTPUT_FILE="$2"
  local ATTEMPT=0
  local SUCCESS=false

  # Build JSON payload
  PAYLOAD=$(jq -n \
    --arg model "$MODEL" \
    --arg system "$SYSTEM_PROMPT" \
    --arg prompt "$PROMPT" \
    --argjson max_tokens "$MAX_TOKENS" \
    --argjson temperature "$TEMPERATURE" \
    '{
      model: $model,
      messages: [
        { role: "system", content: $system },
        { role: "user", content: $prompt }
      ],
      max_tokens: $max_tokens,
      temperature: $temperature
    }')

  while [[ $ATTEMPT -le $MAX_RETRIES && "$SUCCESS" == "false" ]]; do
    if [[ $ATTEMPT -gt 0 ]]; then
      # Exponential backoff: 2s, 4s
      local WAIT=$((2 ** ATTEMPT))
      echo "  Retry $ATTEMPT/$MAX_RETRIES for $MODEL (waiting ${WAIT}s)..." >&2
      sleep "$WAIT"
    fi

    # Call OpenRouter API
    RESPONSE=$(curl -s -w "\n%{http_code}" \
      --max-time "$TIMEOUT" \
      --connect-timeout 10 \
      "https://openrouter.ai/api/v1/chat/completions" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $API_KEY" \
      -H "HTTP-Referer: https://github.com/mix-of-experts-plugin" \
      -H "X-Title: Mix of Experts Plugin" \
      -d "$PAYLOAD" 2>/dev/null) || {
        # curl itself failed (network error, DNS, etc.)
        ATTEMPT=$((ATTEMPT + 1))
        if [[ $ATTEMPT -le $MAX_RETRIES ]]; then
          continue
        fi
        {
          echo "# ERROR from $MODEL"
          echo ""
          echo "**Status**: NETWORK_ERROR"
          echo "**Attempts**: $((ATTEMPT))"
          echo ""
          echo "curl failed — check network connectivity or DNS resolution."
        } > "$OUTPUT_FILE"
        echo "FAILED"
        return
      }

    # Split response body and status code
    HTTP_CODE=$(echo "$RESPONSE" | tail -1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    # Check for success
    if [[ "$HTTP_CODE" -ge 200 && "$HTTP_CODE" -lt 300 ]]; then
      # Validate response has actual content
      CONTENT=$(echo "$BODY" | jq -r '.choices[0].message.content // empty')

      if [[ -z "$CONTENT" ]]; then
        # 200 but empty content — treat as failure
        ATTEMPT=$((ATTEMPT + 1))
        if [[ $ATTEMPT -le $MAX_RETRIES ]]; then
          continue
        fi
        {
          echo "# ERROR from $MODEL"
          echo ""
          echo "**Status**: EMPTY_RESPONSE"
          echo "**HTTP**: $HTTP_CODE"
          echo "**Attempts**: $((ATTEMPT))"
          echo ""
          echo "Model returned 200 but with no content."
        } > "$OUTPUT_FILE"
        echo "FAILED"
        return
      fi

      # Success — extract metadata
      USAGE_PROMPT=$(echo "$BODY" | jq -r '.usage.prompt_tokens // "N/A"')
      USAGE_COMPLETION=$(echo "$BODY" | jq -r '.usage.completion_tokens // "N/A"')
      GEN_ID=$(echo "$BODY" | jq -r '.id // empty')

      {
        echo "# Response from $MODEL"
        echo ""
        echo "**Tokens**: prompt=$USAGE_PROMPT, completion=$USAGE_COMPLETION"
        echo "**Attempts**: $((ATTEMPT + 1))"
        echo ""
        echo "---"
        echo ""
        echo "$CONTENT"
      } > "$OUTPUT_FILE"

      # Save generation ID for cost lookup
      if [[ -n "$GEN_ID" ]]; then
        echo "$GEN_ID" > "${OUTPUT_FILE%.md}.gen-id"
      fi

      SUCCESS=true

    elif [[ "$HTTP_CODE" -eq 429 || "$HTTP_CODE" -ge 500 ]]; then
      # Rate limit or server error — retryable
      ATTEMPT=$((ATTEMPT + 1))
      if [[ $ATTEMPT -le $MAX_RETRIES ]]; then
        continue
      fi
      {
        echo "# ERROR from $MODEL"
        echo ""
        echo "**HTTP Status**: $HTTP_CODE"
        echo "**Attempts**: $((ATTEMPT))"
        echo ""
        echo '```'
        echo "$BODY" | jq -r '.error.message // .' 2>/dev/null || echo "$BODY"
        echo '```'
      } > "$OUTPUT_FILE"
      echo "FAILED"
      return

    else
      # Client error (400, 401, 403, 404) — not retryable
      {
        echo "# ERROR from $MODEL"
        echo ""
        echo "**HTTP Status**: $HTTP_CODE"
        echo "**Attempts**: $((ATTEMPT + 1))"
        echo ""
        echo '```'
        echo "$BODY" | jq -r '.error.message // .' 2>/dev/null || echo "$BODY"
        echo '```'
      } > "$OUTPUT_FILE"
      echo "FAILED"
      return
    fi
  done

  if [[ "$SUCCESS" == "true" ]]; then
    echo "OK"
  fi
}

# ── Query each model in parallel ───────────────────────────────────
PIDS=()
MODEL_LIST=()

for MODEL in "${MODELS[@]}"; do
  MODEL=$(echo "$MODEL" | tr -d ' ')
  MODEL_LIST+=("$MODEL")
  OUTPUT_FILE="$OUTPUT_DIR/$(echo "$MODEL" | tr '/' '_').md"
  RESULT_FILE="$OUTPUT_DIR/$(echo "$MODEL" | tr '/' '_').status"

  # Check cache
  if [[ "$NO_CACHE" != "true" ]]; then
    KEY=$(cache_key "$MODEL")
    CACHED="$CACHE_DIR/$KEY.md"
    if [[ -f "$CACHED" ]]; then
      cp "$CACHED" "$OUTPUT_FILE"
      echo "CACHED" > "$RESULT_FILE"
      continue
    fi
  fi

  (
    RESULT=$(call_model "$MODEL" "$OUTPUT_FILE")
    echo "$RESULT" > "$RESULT_FILE"
    # Save to cache on success
    if [[ "$RESULT" == "OK" && "$NO_CACHE" != "true" ]]; then
      KEY=$(cache_key "$MODEL")
      cp "$OUTPUT_FILE" "$CACHE_DIR/.$KEY.tmp"
      mv "$CACHE_DIR/.$KEY.tmp" "$CACHE_DIR/$KEY.md"
    fi
  ) &
  PIDS+=($!)
done

# Wait for all primary requests
if [[ ${#PIDS[@]} -gt 0 ]]; then
  for PID in "${PIDS[@]}"; do
    wait "$PID" 2>/dev/null || true
  done
fi

# ── Fallback: retry failed models with alternatives ────────────────
FALLBACK_IDX=0
for MODEL in "${MODEL_LIST[@]}"; do
  STATUS_FILE="$OUTPUT_DIR/$(echo "$MODEL" | tr '/' '_').status"
  STATUS=$(cat "$STATUS_FILE" 2>/dev/null || echo "FAILED")

  if [[ "$STATUS" == "FAILED" && $FALLBACK_IDX -lt ${#FALLBACKS[@]} ]]; then
    FALLBACK_MODEL=$(echo "${FALLBACKS[$FALLBACK_IDX]}" | tr -d ' ')
    FALLBACK_IDX=$((FALLBACK_IDX + 1))
    OUTPUT_FILE="$OUTPUT_DIR/$(echo "$MODEL" | tr '/' '_').md"

    echo "  Falling back: $MODEL -> $FALLBACK_MODEL" >&2
    call_model "$FALLBACK_MODEL" "$OUTPUT_FILE" >/dev/null

    # Prepend a note about fallback
    if [[ -f "$OUTPUT_FILE" ]]; then
      TEMP_FILE=$(mktemp)
      _MOE_TEMP_FILES+=("$TEMP_FILE")
      {
        echo "> **Note**: Original model \`$MODEL\` failed. This response is from fallback \`$FALLBACK_MODEL\`."
        echo ""
        cat "$OUTPUT_FILE"
      } > "$TEMP_FILE"
      mv "$TEMP_FILE" "$OUTPUT_FILE"
    fi
  fi
done

# ── Query costs ────────────────────────────────────────────────────
TOTAL_COST="0"
for MODEL in "${MODEL_LIST[@]}"; do
  GEN_ID_FILE="$OUTPUT_DIR/$(echo "$MODEL" | tr '/' '_').gen-id"
  RESPONSE_FILE="$OUTPUT_DIR/$(echo "$MODEL" | tr '/' '_').md"

  [[ -f "$GEN_ID_FILE" ]] || continue
  GEN_ID=$(cat "$GEN_ID_FILE")
  [[ -z "$GEN_ID" ]] && continue

  COST_RESPONSE=$(curl -s --max-time 10 \
    "https://openrouter.ai/api/v1/generation?id=$GEN_ID" \
    -H "Authorization: Bearer $API_KEY" 2>/dev/null) || continue

  COST=$(echo "$COST_RESPONSE" | jq -r '.data.total_cost // empty' 2>/dev/null)
  if [[ -n "$COST" && "$COST" != "null" ]]; then
    # Insert cost into response file after Attempts line
    TEMP_FILE=$(mktemp)
    _MOE_TEMP_FILES+=("$TEMP_FILE")
    awk -v cost="$COST" '/^\*\*Attempts\*\*:/{print; print "**Cost**: $" cost; next}1' "$RESPONSE_FILE" > "$TEMP_FILE"
    mv "$TEMP_FILE" "$RESPONSE_FILE"

    # Update cached version with cost
    if [[ "$NO_CACHE" != "true" ]]; then
      KEY=$(cache_key "$MODEL")
      CACHED="$CACHE_DIR/$KEY.md"
      if [[ -f "$CACHED" ]]; then
        cp "$RESPONSE_FILE" "$CACHE_DIR/.$KEY.tmp"
        mv "$CACHE_DIR/.$KEY.tmp" "$CACHED"
      fi
    fi

    TOTAL_COST=$(echo "$TOTAL_COST + $COST" | bc 2>/dev/null || echo "$TOTAL_COST")
  fi
done

# ── Summary ────────────────────────────────────────────────────────
echo ""
echo "MODEL_RESPONSES:"
SUCCESS_COUNT=0
FAIL_COUNT=0
CACHE_COUNT=0

for MODEL in "${MODEL_LIST[@]}"; do
  OUTPUT_FILE="$OUTPUT_DIR/$(echo "$MODEL" | tr '/' '_').md"
  STATUS_FILE="$OUTPUT_DIR/$(echo "$MODEL" | tr '/' '_').status"
  STATUS=$(cat "$STATUS_FILE" 2>/dev/null || echo "")

  if [[ "$STATUS" == "CACHED" ]]; then
    echo "  CACHE $OUTPUT_FILE"
    CACHE_COUNT=$((CACHE_COUNT + 1))
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
  elif [[ -f "$OUTPUT_FILE" ]]; then
    # Check if it's an error response
    if head -1 "$OUTPUT_FILE" | grep -q "^# ERROR"; then
      echo "  FAIL  $OUTPUT_FILE"
      FAIL_COUNT=$((FAIL_COUNT + 1))
    else
      echo "  OK    $OUTPUT_FILE"
      SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    fi
  else
    echo "  MISS  $MODEL (no output file)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
done

echo ""
CACHE_STR=""
if [[ $CACHE_COUNT -gt 0 ]]; then
  CACHE_STR=" ($CACHE_COUNT cached)"
fi

if [[ "$TOTAL_COST" != "0" ]]; then
  FORMATTED_COST=$(printf "\$%.4f" "$TOTAL_COST" 2>/dev/null || echo "\$$TOTAL_COST")
  echo "SUMMARY: $SUCCESS_COUNT succeeded${CACHE_STR}, $FAIL_COUNT failed, ${#MODEL_LIST[@]} total | Cost: $FORMATTED_COST"
else
  echo "SUMMARY: $SUCCESS_COUNT succeeded${CACHE_STR}, $FAIL_COUNT failed, ${#MODEL_LIST[@]} total"
fi
