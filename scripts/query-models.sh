#!/bin/bash
# query-models.sh - Fan out a prompt to multiple AI models via OpenRouter or Azure AI Foundry
# Usage: bash query-models.sh --settings-file <path> --phase <phase> --prompt-file <path>
#                             [--no-cache] [--confirm-cost] [--estimate-only]
# Exit: 0 = ran (see SUMMARY), 1 = error, 3 = estimated cost above max_cost_usd (needs --confirm-cost)

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
CONFIRM_COST=false
ESTIMATE_ONLY=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --settings-file) SETTINGS_FILE="$2"; shift 2 ;;
    --phase) PHASE="$2"; shift 2 ;;
    --prompt-file) PROMPT_FILE="$2"; shift 2 ;;
    --no-cache) NO_CACHE=true; shift ;;
    --confirm-cost) CONFIRM_COST=true; shift ;;
    --estimate-only) ESTIMATE_ONLY=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Validate required arguments
if [[ -z "$SETTINGS_FILE" || -z "$PHASE" || -z "$PROMPT_FILE" ]]; then
  echo "Usage: bash query-models.sh --settings-file <path> --phase <phase> --prompt-file <path> [--no-cache] [--confirm-cost] [--estimate-only]" >&2
  echo "  --settings-file  Path to .local.md settings file with YAML frontmatter" >&2
  echo "  --phase          Consultation phase: architecture, review, clarify, or ad-hoc" >&2
  echo "  --prompt-file    Path to file containing the prompt to send" >&2
  echo "  --no-cache       Skip cache, force fresh API calls" >&2
  echo "  --confirm-cost   Run even if the estimated cost is above max_cost_usd" >&2
  echo "  --estimate-only  Print the cost estimate and gate result, call no models" >&2
  exit 1
fi

case "$PHASE" in
  architecture|review|clarify|ad-hoc) ;;
  *)
    echo "ERROR: Invalid phase '$PHASE'. Expected one of: architecture, review, clarify, ad-hoc" >&2
    exit 1
    ;;
esac

if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "ERROR: Prompt file not found: $PROMPT_FILE" >&2
  exit 1
fi

# ── Parse settings from YAML frontmatter ───────────────────────────
# AZURE_OPENAI_KEY is accepted as an alias because Azure's own docs and SDKs use both names.
AZURE_ENV_KEY="${AZURE_OPENAI_API_KEY:-${AZURE_OPENAI_KEY:-}}"

# The file is optional only when a provider key is in the env; everything else has defaults
# (except Azure models, which is checked below once the provider is known).
FRONTMATTER=""
if [[ -f "$SETTINGS_FILE" ]]; then
  FRONTMATTER=$(sed -n '/^---$/,/^---$/p' "$SETTINGS_FILE" | sed '1d;$d')
elif [[ -z "${OPENROUTER_API_KEY:-}" && -z "$AZURE_ENV_KEY" ]]; then
  echo "ERROR: Settings file not found: $SETTINGS_FILE" >&2
  echo "Create it, or set OPENROUTER_API_KEY (or AZURE_OPENAI_API_KEY for azure-foundry). See the plugin README." >&2
  exit 1
fi

get_setting() {
  [[ -n "$FRONTMATTER" ]] || return 0
  echo "$FRONTMATTER" | grep "^$1:" | head -1 | sed "s/^$1: *//" | tr -d '"' | tr -d "'" || true
}

PROVIDER=$(get_setting provider)
[[ -z "$PROVIDER" ]] && PROVIDER="openrouter"

case "$PROVIDER" in
  openrouter)
    API_KEY="${OPENROUTER_API_KEY:-}"
    [[ -z "$API_KEY" ]] && API_KEY=$(get_setting openrouter_api_key)
    if [[ -z "$API_KEY" ]]; then
      echo "ERROR: No API key found. Set OPENROUTER_API_KEY env var or add openrouter_api_key to settings file." >&2
      if [[ -n "$AZURE_ENV_KEY" ]]; then
        echo "  An Azure key is set: azure-foundry needs a settings file with 'provider: azure-foundry' and 'models:'." >&2
      fi
      exit 1
    fi
    if [[ ! "$API_KEY" =~ ^sk-or- ]]; then
      echo "WARNING: API key does not start with 'sk-or-'. It may be invalid." >&2
    fi
    ;;
  azure-foundry)
    API_KEY="$AZURE_ENV_KEY"
    [[ -z "$API_KEY" ]] && API_KEY=$(get_setting azure_api_key)
    if [[ -z "$API_KEY" ]]; then
      echo "ERROR: No Azure key found. Set AZURE_OPENAI_API_KEY (or AZURE_OPENAI_KEY) or add azure_api_key to settings file." >&2
      exit 1
    fi
    AZURE_ENDPOINT="${AZURE_OPENAI_ENDPOINT:-}"
    [[ -z "$AZURE_ENDPOINT" ]] && AZURE_ENDPOINT=$(get_setting azure_endpoint)
    # Accept the endpoint as people usually paste it: with a trailing slash, or already ending
    # in /openai/v1 (the SDK base_url form). Without this the route doubles and returns 404.
    AZURE_ENDPOINT="${AZURE_ENDPOINT%/}"
    AZURE_ENDPOINT="${AZURE_ENDPOINT%/openai/v1}"
    AZURE_ENDPOINT="${AZURE_ENDPOINT%/openai}"
    if [[ "$AZURE_ENDPOINT" == */api/projects/* ]]; then
      # Microsoft documents project endpoints with Entra ID tokens only; an API key there
      # typically returns 401, so say so up front instead of leaving a bare HTTP error.
      echo "WARNING: $AZURE_ENDPOINT is a Foundry project endpoint. API keys usually need the resource endpoint (https://<resource>.services.ai.azure.com) instead." >&2
    fi
    if [[ -z "$AZURE_ENDPOINT" ]]; then
      echo "ERROR: No Azure endpoint found. Set AZURE_OPENAI_ENDPOINT or add azure_endpoint to settings file." >&2
      exit 1
    fi
    ;;
  *)
    echo "ERROR: Unknown provider '$PROVIDER'. Expected: openrouter or azure-foundry" >&2
    exit 1
    ;;
esac

# Extract models list (comma-separated in settings). models_<phase> overrides models for that
# round only, so e.g. the cheap clarify round can use cheaper models than architecture.
MODELS_RAW=$(get_setting "models_${PHASE}")
[[ -z "$MODELS_RAW" ]] && MODELS_RAW=$(get_setting models)
if [[ -z "$MODELS_RAW" ]]; then
  if [[ "$PROVIDER" == "azure-foundry" ]]; then
    # Foundry model names are deployment names chosen per resource; there is no sane default.
    echo "ERROR: provider azure-foundry requires 'models:' (or 'models_${PHASE}:') with Foundry deployment names in the settings file." >&2
    exit 1
  fi
  MODELS_RAW="openai/gpt-5.2,google/gemini-3-flash-preview,deepseek/deepseek-v3.2-20251201"
fi

# Extract optional fields (use defaults if no frontmatter or field missing)
MAX_TOKENS=$(get_setting max_tokens)
TEMPERATURE=$(get_setting temperature)
TIMEOUT=$(get_setting timeout)
MAX_RETRIES=$(get_setting retries)
FALLBACKS_RAW=$(get_setting fallback_models)
STYLES_RAW=$(get_setting styles)
MAX_COST_USD=$(get_setting max_cost_usd)
[[ -z "$MAX_TOKENS" ]] && MAX_TOKENS=8000
[[ -z "$TEMPERATURE" ]] && TEMPERATURE=0.3
[[ -z "$TIMEOUT" ]] && TIMEOUT=300
[[ -z "$MAX_RETRIES" ]] && MAX_RETRIES=1
[[ -z "$STYLES_RAW" ]] && STYLES_RAW="ship,scale,simplify"
[[ -z "$MAX_COST_USD" ]] && MAX_COST_USD=1

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
  if [[ "$PROVIDER" == "azure-foundry" ]]; then
    if ! [[ "$MODEL" =~ ^[a-zA-Z0-9._-]+$ ]]; then
      echo "ERROR: Invalid Azure deployment name: '$MODEL'. Expected letters, digits, '.', '_' or '-'" >&2
      exit 1
    fi
  elif ! [[ "$MODEL" =~ ^[a-zA-Z0-9_-]+/[a-zA-Z0-9._-]+$ ]]; then
    echo "ERROR: Invalid model name: '$MODEL'. Expected format: provider/model-name" >&2
    exit 1
  fi
}

validate_positive_int "max_tokens" "$MAX_TOKENS"
validate_temperature "$TEMPERATURE"
validate_positive_int "timeout" "$TIMEOUT"
validate_non_negative_int "retries" "$MAX_RETRIES"
if ! [[ "$MAX_COST_USD" =~ ^[0-9]+\.?[0-9]*$ ]]; then
  echo "ERROR: max_cost_usd must be a non-negative number, got '$MAX_COST_USD'" >&2
  exit 1
fi

# ── Dev styles ─────────────────────────────────────────────────────
# Each expert gets one professional lens, assigned by model position (rotating). Three models
# with the same instructions converge on the same answer; distinct lenses widen what the
# panel notices, while every expert still answers the full required structure.
STYLES=()
if [[ "$STYLES_RAW" != "off" && "$STYLES_RAW" != "none" ]]; then
  IFS=',' read -ra STYLES <<< "$(echo "$STYLES_RAW" | tr -d ' ')"
  for _ST in "${STYLES[@]}"; do
    case "$_ST" in
      ship|scale|simplify|neutral) ;;
      *) echo "ERROR: Unknown style '$_ST'. Expected ship, scale, simplify, neutral, or 'off'" >&2; exit 1 ;;
    esac
  done
fi

style_for_index() {
  if [[ ${#STYLES[@]} -eq 0 ]]; then
    echo "neutral"
  else
    echo "${STYLES[$(( $1 % ${#STYLES[@]} ))]}"
  fi
}

style_text() {
  case "$1" in
    ship) echo "You are a pragmatic product engineer from a fast-moving startup. Favour the simplest design that ships safely now, call out over-engineering, and say what can wait." ;;
    scale) echo "You are a staff/SRE engineer who runs systems in production. Focus on failure modes, concurrency, data integrity, observability, and what breaks at 10x load or at 3am." ;;
    simplify) echo "You are a principal engineer who maintains code for years. Favour clear boundaries, few moving parts, readability, testability, and low long-term cost." ;;
    *) echo "" ;;
  esac
}

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
  local MODEL="$1" STYLE="${2:-neutral}"
  # PROVIDER is part of the key: the same model name on two providers is not the same model.
  # SYSTEM_HASH is too, so editing a phase's required sections never serves stale-format answers.
  echo -n "${PROVIDER}|${PHASE}|${MODEL}|${STYLE}|${TEMPERATURE}|${MAX_TOKENS}|${PROMPT_HASH}|${SYSTEM_HASH}" | shasum -a 256 2>/dev/null | cut -d' ' -f1 || \
    echo -n "${PROVIDER}|${PHASE}|${MODEL}|${STYLE}|${TEMPERATURE}|${MAX_TOKENS}|${PROMPT_HASH}|${SYSTEM_HASH}" | md5 2>/dev/null
}

# ── Create output directory ────────────────────────────────────────
OUTPUT_DIR=$(mktemp -d)

# Track temp files for cleanup on exit/signal
_MOE_TEMP_FILES=()

_moe_cleanup() {
  if [[ ${#_MOE_TEMP_FILES[@]} -gt 0 ]]; then
    for f in "${_MOE_TEMP_FILES[@]}"; do
      rm -f "$f" 2>/dev/null
    done
  fi
  rm -f "$OUTPUT_DIR"/*.status "$OUTPUT_DIR"/*.cost 2>/dev/null
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
State HIGH, MEDIUM, or LOW confidence in this proposal, with a one-sentence justification. Then name the single piece of missing information that would most change this proposal, or write 'Nothing material.'.

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
  clarify)
    SYSTEM_PROMPT="You are a senior software architect in the clarification round that precedes an architecture proposal. Read the prompt package and tell the operator (the lead engineer who wrote it) what you need before you could propose a sound architecture for the explicit ask: decisions only they can make, and evidence they can fetch. Do NOT propose an architecture in this phase. Structure your response with these exact sections:

## Summary
A 2-3 sentence restatement of the ask and the main uncertainty you see.

## Clarifying Questions
Decisions or facts only the operator or user can supply (intent, priorities, constraints). A numbered list of up to 3 questions (at most 5, only if every one is essential). Each must be answerable in a few lines and must change your design depending on the answer; add one sentence on why it matters. If nothing needs clarifying, this section must be exactly: None

## Context Requests
Evidence the operator can gather that would most sharpen your conclusion: specific files, schemas, interfaces, logs, metrics, dependency versions, prior attempts. A numbered list of up to 3, most valuable first, each formatted as: **what to include** — how it would change your recommendation — where to find it (path, command, or owner) if you can tell. Do not request what the package already contains. If the package is sufficient, this section must be exactly: None

## Confidence
State HIGH, MEDIUM, or LOW confidence that, with these questions answered and this context provided, you could propose a sound architecture, with a one-sentence justification.

Every section is required.

IMPORTANT: Your response is limited to ${MAX_TOKENS} tokens. Be concise."
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
State HIGH, MEDIUM, or LOW confidence in this response, with a one-sentence justification. Then name the single piece of missing information that would most change this answer, or write 'Nothing material.'.

Be specific. Every section is required.

IMPORTANT: Your response is limited to ${MAX_TOKENS} tokens. Be concise and prioritize the most valuable insights."
    ;;
esac

SYSTEM_HASH=$(printf '%s' "$SYSTEM_PROMPT" | shasum -a 256 2>/dev/null | cut -d' ' -f1 || echo "nohash")

# Appended on retries: the usual failure is an empty or truncated answer, and restating the
# contract measurably reduces the chance the second attempt fails the same way.
RETRY_ADDENDUM="RETRY INSTRUCTIONS (prior attempt failed, was empty, or incomplete):
- This is attempt __ATTEMPT__. Produce a complete response now.
- Emit every required ## section for this phase with real content (no placeholders).
- No preamble, apologies, or meta commentary about retries.
- If uncertain, still answer and mark Confidence LOW with a one-sentence reason.
- Prefer concrete, opinionated claims over hedges. Stay within the token budget."

# ── Pre-flight cost estimation ────────────────────────────────────
_PROMPT_CHARS=$(wc -c < "$PROMPT_FILE" | tr -d ' ')
_SYSTEM_CHARS=${#SYSTEM_PROMPT}
_EST_PROMPT_TOKENS=$(( (_PROMPT_CHARS + _SYSTEM_CHARS) / 4 ))
IFS=',' read -ra _EST_MODELS <<< "$MODELS_RAW"
_NUM_MODELS=${#_EST_MODELS[@]}
echo "Estimated: ~${_EST_PROMPT_TOKENS} prompt tokens x ${_NUM_MODELS} models | Max completion: ${MAX_TOKENS} tokens/model" >&2

# Dollar estimate = every uncached model writing a full max_tokens answer, priced from
# OpenRouter's public model list. Azure publishes no per-call prices, so it is not gated.
EST_COST=""
if [[ "$PROVIDER" == "openrouter" ]]; then
  # The full model list is several hundred KB and slow to serve, so it is cached for a day;
  # prices change rarely and this is an estimate, not a bill.
  PRICE_CACHE="$CACHE_DIR/openrouter-models.json"
  if [[ -z "$(find "$PRICE_CACHE" -mtime -1 2>/dev/null)" ]]; then
    PRICE_TMP="$CACHE_DIR/.openrouter-models.$$"
    if curl -s --max-time 30 "https://openrouter.ai/api/v1/models" -o "$PRICE_TMP" 2>/dev/null \
      && jq -e '.data | length > 0' "$PRICE_TMP" >/dev/null 2>&1; then
      mv -f "$PRICE_TMP" "$PRICE_CACHE"
    else
      rm -f "$PRICE_TMP"
    fi
  fi
  PRICES=$(jq -c '[.data[] | {id, p: (.pricing.prompt | tonumber? // null), c: (.pricing.completion | tonumber? // null)}]' \
    "$PRICE_CACHE" 2>/dev/null || true)
  if [[ -n "$PRICES" ]]; then
    EST_COST=0
    _UNPRICED=""
    _IDX=0
    for _EM in "${_EST_MODELS[@]}"; do
      _EM=$(echo "$_EM" | tr -d ' ')
      _ST=$(style_for_index "$_IDX")
      _IDX=$((_IDX + 1))
      if [[ "$NO_CACHE" != "true" && -f "$CACHE_DIR/$(cache_key "$_EM" "$_ST").md" ]]; then
        continue
      fi
      _MC=$(echo "$PRICES" | jq -r --arg id "$_EM" --argjson pt "$_EST_PROMPT_TOKENS" --argjson ct "$MAX_TOKENS" \
        'map(select(.id == $id and .p != null and .c != null)) | if length > 0 then (.[0].p * $pt + .[0].c * $ct) else empty end' 2>/dev/null || true)
      if [[ -z "$_MC" ]]; then
        _UNPRICED+=" $_EM"
      else
        EST_COST=$(echo "$EST_COST + $_MC" | bc -l)
      fi
    done
    echo "Estimated max cost: $(printf '$%.4f' "$EST_COST") (one full-length answer per uncached model; retries can add more)${_UNPRICED:+ | no price listed for:$_UNPRICED}" >&2
  else
    echo "Estimated max cost: unknown (could not fetch OpenRouter prices)" >&2
  fi
fi

if [[ -n "$EST_COST" && $(echo "$EST_COST > $MAX_COST_USD" | bc -l) -eq 1 && "$CONFIRM_COST" != "true" ]]; then
  echo "COST_GATE: estimated $(printf '$%.2f' "$EST_COST") exceeds max_cost_usd $(printf '$%.2f' "$MAX_COST_USD"). Ask the user, then re-run with --confirm-cost."
  rmdir "$OUTPUT_DIR" 2>/dev/null || true
  exit 3
fi
if [[ "$ESTIMATE_ONLY" == "true" ]]; then
  echo "COST_GATE: ok"
  rmdir "$OUTPUT_DIR" 2>/dev/null || true
  exit 0
fi

# ── API call function with retries ─────────────────────────────────
# Appends rather than overwrites: a fallback reuses the failed model's file name, and a paid
# attempt that later fails (empty answer, truncation then 5xx) must still be counted.
record_cost() {
  local FILE="$1" SPENT="$2"
  if [[ $(echo "$SPENT > 0" | bc -l) -eq 1 ]]; then
    echo "$SPENT" >> "${FILE%.md}.cost"
  fi
}

call_model() {
  local MODEL="$1"
  local OUTPUT_FILE="$2"
  local STYLE="${3:-neutral}"
  local ATTEMPT=0
  local SUCCESS=false
  local CURL_FAILED=false
  local TOKENS="$MAX_TOKENS"
  local EXPANDED=false
  local SPENT=0
  local SERVER_WAIT=""
  local HDR_FILE
  HDR_FILE=$(mktemp)
  local BASE_SYSTEM="$SYSTEM_PROMPT"
  local STYLE_LINE
  STYLE_LINE=$(style_text "$STYLE")
  if [[ -n "$STYLE_LINE" ]]; then
    BASE_SYSTEM="$STYLE_LINE Treat this as your emphasis, not a blind spot: still cover every required section.

$SYSTEM_PROMPT"
  fi

  while [[ $ATTEMPT -le $MAX_RETRIES && "$SUCCESS" == "false" ]]; do
    if [[ $ATTEMPT -gt 0 ]]; then
      # Exponential backoff (2s, 4s, ...), unless the server said how long to wait: Azure's
      # per-minute token limits commonly ask for 8-60s, which a 2s retry would just hit again.
      local WAIT=$((2 ** ATTEMPT))
      if [[ -n "$SERVER_WAIT" ]]; then
        WAIT="$SERVER_WAIT"
        SERVER_WAIT=""
      fi
      echo "  Retry $ATTEMPT/$MAX_RETRIES for $MODEL (waiting ${WAIT}s)..." >&2
      sleep "$WAIT"
    fi

    local EFFECTIVE_SYSTEM="$BASE_SYSTEM"
    if [[ $ATTEMPT -ge 1 ]]; then
      EFFECTIVE_SYSTEM="$BASE_SYSTEM

${RETRY_ADDENDUM//__ATTEMPT__/$((ATTEMPT + 1))}"
    fi

    if [[ "$PROVIDER" == "azure-foundry" ]]; then
      # Foundry wants max_completion_tokens, and GPT-5.x deployments reject any temperature
      # other than the default, so it is omitted rather than sent.
      PAYLOAD=$(jq -n \
        --arg model "$MODEL" \
        --arg system "$EFFECTIVE_SYSTEM" \
        --arg prompt "$PROMPT" \
        --argjson max_tokens "$TOKENS" \
        '{
          model: $model,
          messages: [
            { role: "system", content: $system },
            { role: "user", content: $prompt }
          ],
          max_completion_tokens: $max_tokens
        }')
      RESPONSE=$(curl -s -w "\n%{http_code}" \
        --max-time "$TIMEOUT" \
        --connect-timeout 10 \
        "$AZURE_ENDPOINT/openai/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -H "api-key: $API_KEY" \
        -D "$HDR_FILE" \
        -d "$PAYLOAD" 2>/dev/null) || CURL_FAILED=true
    else
      PAYLOAD=$(jq -n \
        --arg model "$MODEL" \
        --arg system "$EFFECTIVE_SYSTEM" \
        --arg prompt "$PROMPT" \
        --argjson max_tokens "$TOKENS" \
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
      RESPONSE=$(curl -s -w "\n%{http_code}" \
        --max-time "$TIMEOUT" \
        --connect-timeout 10 \
        "https://openrouter.ai/api/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $API_KEY" \
        -H "HTTP-Referer: https://github.com/mix-of-experts-plugin" \
        -H "X-Title: Mix of Experts Plugin" \
        -D "$HDR_FILE" \
        -d "$PAYLOAD" 2>/dev/null) || CURL_FAILED=true
    fi

    if [[ "$CURL_FAILED" == "true" ]]; then
      CURL_FAILED=false
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
      record_cost "$OUTPUT_FILE" "$SPENT"
      rm -f "$HDR_FILE"
      echo "FAILED"
      return
    fi

    # Split response body and status code
    HTTP_CODE=$(echo "$RESPONSE" | tail -1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    # Check for success
    if [[ "$HTTP_CODE" -ge 200 && "$HTTP_CODE" -lt 300 ]]; then
      # OpenRouter reports cost inline; Foundry does not. Every paid attempt counts.
      local CALL_COST
      CALL_COST=$(echo "$BODY" | jq -r '.usage.cost // empty' 2>/dev/null || true)
      [[ -n "$CALL_COST" ]] && SPENT=$(echo "$SPENT + $CALL_COST" | bc -l)

      # finish_reason=length means the answer was cut off at the token cap. It reads like a
      # complete answer that just skipped its last sections, so it is retried once with a
      # doubled budget and, if still cut off, labelled TRUNCATED and never cached. Checked
      # before the empty-content test: reasoning models can spend the whole budget thinking
      # and return no content at all, which is the same problem, not a transient failure.
      local FINISH
      FINISH=$(echo "$BODY" | jq -r '.choices[0].finish_reason // empty' 2>/dev/null || true)
      # A content-filtered answer is empty or partial and would be blocked again on retry
      # (Microsoft: don't resend the same blocked prompt), so it fails immediately.
      if [[ "$FINISH" == "content_filter" ]]; then
        {
          echo "# ERROR from $MODEL"
          echo ""
          echo "**Status**: CONTENT_FILTERED"
          echo "**Attempts**: $((ATTEMPT + 1))"
          echo ""
          echo "The provider's content filter blocked this response. Rephrase the prompt package; retrying it unchanged will be blocked again."
        } > "$OUTPUT_FILE"
        rm -f "$HDR_FILE"
        record_cost "$OUTPUT_FILE" "$SPENT"
        echo "FAILED"
        return
      fi
      if [[ "$FINISH" == "length" && "$EXPANDED" == "false" ]]; then
        EXPANDED=true
        TOKENS=$((TOKENS * 2))
        echo "  Truncated: $MODEL hit the token cap, retrying with max_tokens=$TOKENS..." >&2
        continue
      fi

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
          if [[ "$FINISH" == "length" ]]; then
            echo "**Finish**: length — all max_tokens=$TOKENS went to reasoning before any answer text; raise max_tokens"
          fi
          echo ""
          echo "Model returned 200 but with no content."
        } > "$OUTPUT_FILE"
        record_cost "$OUTPUT_FILE" "$SPENT"
        rm -f "$HDR_FILE"
        echo "FAILED"
        return
      fi

      USAGE_PROMPT=$(echo "$BODY" | jq -r '.usage.prompt_tokens // "N/A"')
      USAGE_COMPLETION=$(echo "$BODY" | jq -r '.usage.completion_tokens // "N/A"')

      {
        echo "# Response from $MODEL"
        echo ""
        echo "**Provider**: $PROVIDER"
        echo "**Style**: $STYLE"
        echo "**Tokens**: prompt=$USAGE_PROMPT, completion=$USAGE_COMPLETION"
        echo "**Attempts**: $((ATTEMPT + 1))$([[ "$EXPANDED" == "true" ]] && echo " (+1 with max_tokens=$TOKENS)")"
        [[ "$PROVIDER" == "openrouter" ]] && printf '**Cost**: $%.4f\n' "$SPENT"
        [[ "$FINISH" == "length" ]] && echo "**Status**: TRUNCATED — cut off at max_tokens=$TOKENS; trailing sections may be missing"
        echo ""
        echo "---"
        echo ""
        echo "$CONTENT"
      } > "$OUTPUT_FILE"

      record_cost "$OUTPUT_FILE" "$SPENT"
      SUCCESS=true

    elif [[ "$HTTP_CODE" -eq 429 || "$HTTP_CODE" -ge 500 ]]; then
      # Rate limit or server error — retryable. Honour Retry-After (seconds), capped so one
      # throttled model cannot stall the whole fan-out for minutes.
      local RETRY_AFTER
      RETRY_AFTER=$(tr -d '\r' < "$HDR_FILE" | awk 'tolower($1)=="retry-after:" {v=$2} END {print v}')
      if [[ "$RETRY_AFTER" =~ ^[0-9]+$ ]]; then
        SERVER_WAIT=$(( RETRY_AFTER > 60 ? 60 : (RETRY_AFTER < 1 ? 1 : RETRY_AFTER) ))
      fi
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
      record_cost "$OUTPUT_FILE" "$SPENT"
      rm -f "$HDR_FILE"
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
      record_cost "$OUTPUT_FILE" "$SPENT"
      rm -f "$HDR_FILE"
      echo "FAILED"
      return
    fi
  done

  rm -f "$HDR_FILE"
  if [[ "$SUCCESS" == "true" ]]; then
    if grep -q '^\*\*Status\*\*: TRUNCATED' "$OUTPUT_FILE"; then
      echo "TRUNCATED"
    else
      echo "OK"
    fi
  fi
}

# ── Query each model in parallel ───────────────────────────────────
PIDS=()
MODEL_LIST=()
STYLE_LIST=()

for MODEL in "${MODELS[@]}"; do
  MODEL=$(echo "$MODEL" | tr -d ' ')
  STYLE=$(style_for_index "${#MODEL_LIST[@]}")
  MODEL_LIST+=("$MODEL")
  STYLE_LIST+=("$STYLE")
  OUTPUT_FILE="$OUTPUT_DIR/$(echo "$MODEL" | tr '/' '_').md"
  RESULT_FILE="$OUTPUT_DIR/$(echo "$MODEL" | tr '/' '_').status"

  # Check cache
  if [[ "$NO_CACHE" != "true" ]]; then
    KEY=$(cache_key "$MODEL" "$STYLE")
    CACHED="$CACHE_DIR/$KEY.md"
    if [[ -f "$CACHED" ]]; then
      cp "$CACHED" "$OUTPUT_FILE"
      echo "CACHED" > "$RESULT_FILE"
      continue
    fi
  fi

  (
    RESULT=$(call_model "$MODEL" "$OUTPUT_FILE" "$STYLE")
    echo "$RESULT" > "$RESULT_FILE"
    # Cache complete answers only; a TRUNCATED one would be replayed forever.
    if [[ "$RESULT" == "OK" && "$NO_CACHE" != "true" ]]; then
      KEY=$(cache_key "$MODEL" "$STYLE")
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
_MI=0
for MODEL in "${MODEL_LIST[@]}"; do
  STYLE="${STYLE_LIST[$_MI]}"
  _MI=$((_MI + 1))
  STATUS_FILE="$OUTPUT_DIR/$(echo "$MODEL" | tr '/' '_').status"
  STATUS=$(cat "$STATUS_FILE" 2>/dev/null || echo "FAILED")

  if [[ "$STATUS" == "FAILED" && $FALLBACK_IDX -lt ${#FALLBACKS[@]} ]]; then
    FALLBACK_MODEL=$(echo "${FALLBACKS[$FALLBACK_IDX]}" | tr -d ' ')
    FALLBACK_IDX=$((FALLBACK_IDX + 1))
    OUTPUT_FILE="$OUTPUT_DIR/$(echo "$MODEL" | tr '/' '_').md"

    echo "  Falling back: $MODEL -> $FALLBACK_MODEL" >&2
    # The fallback's own outcome is what counts: the note prepended below would otherwise
    # hide a "# ERROR" header and make a failed fallback look like a success.
    call_model "$FALLBACK_MODEL" "$OUTPUT_FILE" "$STYLE" > "$STATUS_FILE"

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

# ── Cost of this run (from inline usage; cached answers cost nothing) ─
TOTAL_COST="0"
for COST_FILE in "$OUTPUT_DIR"/*.cost; do
  [[ -f "$COST_FILE" ]] || continue
  while read -r LINE_COST; do
    [[ -n "$LINE_COST" ]] && TOTAL_COST=$(echo "$TOTAL_COST + $LINE_COST" | bc -l 2>/dev/null || echo "$TOTAL_COST")
  done < "$COST_FILE"
done

# ── Summary ────────────────────────────────────────────────────────
echo ""
echo "MODEL_RESPONSES:"
SUCCESS_COUNT=0
FAIL_COUNT=0
CACHE_COUNT=0
TRUNC_COUNT=0

for MODEL in "${MODEL_LIST[@]}"; do
  OUTPUT_FILE="$OUTPUT_DIR/$(echo "$MODEL" | tr '/' '_').md"
  STATUS_FILE="$OUTPUT_DIR/$(echo "$MODEL" | tr '/' '_').status"
  STATUS=$(cat "$STATUS_FILE" 2>/dev/null || echo "")

  if [[ ! -f "$OUTPUT_FILE" ]]; then
    echo "  MISS  $MODEL (no output file)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    continue
  fi
  case "$STATUS" in
    CACHED)
      echo "  CACHE $OUTPUT_FILE"
      CACHE_COUNT=$((CACHE_COUNT + 1))
      SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
      ;;
    OK)
      echo "  OK    $OUTPUT_FILE"
      SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
      ;;
    TRUNCATED)
      echo "  TRUNC $OUTPUT_FILE"
      TRUNC_COUNT=$((TRUNC_COUNT + 1))
      SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
      ;;
    *)
      echo "  FAIL  $OUTPUT_FILE"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      ;;
  esac
done

echo ""
NOTES=()
[[ $TRUNC_COUNT -gt 0 ]] && NOTES+=("$TRUNC_COUNT truncated")
[[ $CACHE_COUNT -gt 0 ]] && NOTES+=("$CACHE_COUNT cached")
NOTE_STR=""
if [[ ${#NOTES[@]} -gt 0 ]]; then
  NOTE_STR=" ($(IFS=,; echo "${NOTES[*]}" | sed 's/,/, /g'))"
fi

COST_STR=""
if [[ "$PROVIDER" == "openrouter" ]]; then
  COST_STR=" | Cost: $(printf '$%.4f' "$TOTAL_COST")"
fi
echo "SUMMARY: $SUCCESS_COUNT succeeded${NOTE_STR}, $FAIL_COUNT failed, ${#MODEL_LIST[@]} total${COST_STR}"
