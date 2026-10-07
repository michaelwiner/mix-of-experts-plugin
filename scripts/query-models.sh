#!/bin/bash
# query-models.sh - Fan out a prompt to multiple AI models via OpenRouter or Azure AI Foundry
# Usage: bash query-models.sh --settings-file <path> --phase <phase> --prompt-file <path>
#                             [--models a,b] [--swarm] [--no-cache] [--confirm-cost] [--estimate-only]
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
MODELS_OVERRIDE=""
CONFIRM_COST=false
ESTIMATE_ONLY=false
SWARM_FLAG=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --settings-file) SETTINGS_FILE="$2"; shift 2 ;;
    --phase) PHASE="$2"; shift 2 ;;
    --prompt-file) PROMPT_FILE="$2"; shift 2 ;;
    --no-cache) NO_CACHE=true; shift ;;
    --models) MODELS_OVERRIDE="$2"; shift 2 ;;
    --confirm-cost) CONFIRM_COST=true; shift ;;
    --estimate-only) ESTIMATE_ONLY=true; shift ;;
    --swarm) SWARM_FLAG=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Validate required arguments
if [[ -z "$SETTINGS_FILE" || -z "$PHASE" || -z "$PROMPT_FILE" ]]; then
  echo "Usage: bash query-models.sh --settings-file <path> --phase <phase> --prompt-file <path> [--models a,b] [--swarm] [--no-cache] [--confirm-cost] [--estimate-only]" >&2
  echo "  --settings-file  Path to .local.md settings file with YAML frontmatter" >&2
  echo "  --phase          Consultation phase: architecture, review, clarify, challenge, or ad-hoc" >&2
  echo "  --prompt-file    Path to file containing the prompt to send" >&2
  echo "  --no-cache       Skip cache, force fresh API calls" >&2
  echo "  --models         Comma-separated models for this run, overriding the settings file" >&2
  echo "  --swarm          Full swarm: one seat per angle, each answering this phase's full prompt" >&2
  echo "  --confirm-cost   Run even if the estimated cost is above max_cost_usd" >&2
  echo "  --estimate-only  Print the cost estimate and gate result, call no models" >&2
  exit 1
fi

case "$PHASE" in
  architecture|review|clarify|challenge|ad-hoc) ;;
  *)
    echo "ERROR: Invalid phase '$PHASE'. Expected one of: architecture, review, clarify, challenge, ad-hoc" >&2
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

# Swarm: `--swarm` on a phase runs one seat per angle instead of the panel. Each seat answers
# that phase's whole prompt, with its angle as emphasis, like a panel expert with a dev style.
if [[ "$SWARM_FLAG" == "true" ]]; then
  case "$PHASE" in
    clarify|architecture|review|ad-hoc) ;;
    *) echo "ERROR: --swarm applies to clarify, architecture, review or ad-hoc" >&2; exit 1 ;;
  esac
fi

# Extract models list (comma-separated in settings). models_<phase> overrides models for that
# round only, so e.g. the cheap clarify round can use cheaper models than architecture.
# A swarm never falls back to the panel's `models`: ten seats of a panel model is a different
# bill from ten seats of a cheap one.
MODELS_RAW="$MODELS_OVERRIDE"
if [[ "$SWARM_FLAG" == "true" ]]; then
  [[ -z "$MODELS_RAW" ]] && MODELS_RAW=$(get_setting models_swarm)
else
  [[ -z "$MODELS_RAW" ]] && MODELS_RAW=$(get_setting "models_${PHASE}")
  [[ -z "$MODELS_RAW" ]] && MODELS_RAW=$(get_setting models)
fi
if [[ -z "$MODELS_RAW" ]]; then
  if [[ "$PROVIDER" == "azure-foundry" ]]; then
    # Foundry model names are deployment names chosen per resource; there is no sane default.
    echo "ERROR: provider azure-foundry requires 'models:' (or 'models_${PHASE}:') with Foundry deployment names in the settings file." >&2
    exit 1
  fi
  # The challenge round wants one opponent, not a panel: a second critic mostly repeats the
  # first, and the value is the objection, not a vote. A cheap model does this well.
  # A swarm is many cheap members whose diversity comes from their angles, not their models.
  if [[ "$PHASE" == "challenge" || "$SWARM_FLAG" == "true" ]]; then
    MODELS_RAW="openai/gpt-6-luna"
  else
    MODELS_RAW="openai/gpt-6-sol,google/gemini-3.8-flash,x-ai/grok-4.7"
  fi
fi

# A swarm has swarm_size members, one per angle (default: as many as there are angles). The
# model list is cycled to fill the seats, so one model, or a small mix, fills every seat.
SWARM_ANGLES_RAW=$(get_setting swarm_angles)
[[ -z "$SWARM_ANGLES_RAW" ]] && SWARM_ANGLES_RAW="security,operations,data,performance,simplicity,product,testing,cost,rollout,contrarian"
IFS=',' read -ra _SWARM_ANGLES <<< "$(echo "$SWARM_ANGLES_RAW" | tr -d ' ')"
SWARM_SIZE=$(get_setting swarm_size)
[[ -z "$SWARM_SIZE" ]] && SWARM_SIZE=${#_SWARM_ANGLES[@]}
if [[ "$SWARM_FLAG" == "true" ]]; then
  if ! [[ "$SWARM_SIZE" =~ ^[0-9]+$ ]] || [[ "$SWARM_SIZE" -lt 2 || "$SWARM_SIZE" -gt 20 ]]; then
    echo "ERROR: swarm_size must be an integer from 2 to 20, got '$SWARM_SIZE'" >&2
    exit 1
  fi
  IFS=',' read -ra _SWARM_BASE <<< "$(echo "$MODELS_RAW" | tr -d ' ')"
  for _M in "${_SWARM_BASE[@]}"; do
    if [[ -z "$_M" ]]; then
      echo "ERROR: the swarm model list '$MODELS_RAW' has an empty entry" >&2
      exit 1
    fi
  done
  if [[ ${#_SWARM_BASE[@]} -gt $SWARM_SIZE ]]; then
    echo "WARNING: ${#_SWARM_BASE[@]} models listed for $SWARM_SIZE swarm seats; the last $(( ${#_SWARM_BASE[@]} - SWARM_SIZE )) are not used" >&2
  fi
  _SWARM_MODELS=()
  for (( _I = 0; _I < SWARM_SIZE; _I++ )); do
    _SWARM_MODELS+=("${_SWARM_BASE[$(( _I % ${#_SWARM_BASE[@]} ))]}")
  done
  MODELS_RAW=$(IFS=,; echo "${_SWARM_MODELS[*]}")
fi

# Extract optional fields (use defaults if no frontmatter or field missing)
MAX_TOKENS=$(get_setting max_tokens)
TEMPERATURE=$(get_setting temperature)
TIMEOUT=$(get_setting timeout)
MAX_RETRIES=$(get_setting retries)
FALLBACKS_RAW=$(get_setting fallback_models)
STYLES_RAW=$(get_setting styles)
REASONING_EFFORT=$(get_setting reasoning_effort)
# Quorum and grace: once quorum% of the members have answered, the rest get `grace` more seconds,
# then the run continues without them. One slow member should not hold up the whole run.
if [[ "$SWARM_FLAG" == "true" ]]; then
  QUORUM_PCT=$(get_setting swarm_quorum); GRACE_S=$(get_setting swarm_grace)
  [[ -z "$QUORUM_PCT" ]] && QUORUM_PCT=80
  [[ -z "$GRACE_S" ]] && GRACE_S=30
else
  QUORUM_PCT=$(get_setting quorum); GRACE_S=$(get_setting grace)
  [[ -z "$QUORUM_PCT" ]] && QUORUM_PCT=66   # 2 of 3
  [[ -z "$GRACE_S" ]] && GRACE_S=60
fi
[[ "$SWARM_FLAG" == "true" && -n "$(get_setting swarm_reasoning_effort)" ]] && REASONING_EFFORT=$(get_setting swarm_reasoning_effort)
WEB_RAW=$(get_setting web_search)
WEB_MAX=$(get_setting web_search_max)
WEB_ENGINE=$(get_setting web_search_engine)
MAX_COST_USD=$(get_setting max_cost_usd)
MAX_PARALLEL=$(get_setting max_parallel)
[[ -z "$MAX_TOKENS" ]] && MAX_TOKENS=8000
[[ -z "$TEMPERATURE" ]] && TEMPERATURE=0.3
[[ -z "$TIMEOUT" ]] && TIMEOUT=300
[[ -z "$MAX_RETRIES" ]] && MAX_RETRIES=1
[[ -z "$STYLES_RAW" ]] && STYLES_RAW="ship,scale,simplify"
[[ -z "$MAX_COST_USD" ]] && MAX_COST_USD=0.5
# Caps concurrent requests. By default every member of a run (up to 10, or every swarm seat) is in
# flight at once: a run lasts as long as its slowest member, so a second wave roughly doubles it.
if [[ -z "$MAX_PARALLEL" ]]; then
  MAX_PARALLEL=10
  [[ "$SWARM_FLAG" == "true" && $SWARM_SIZE -gt $MAX_PARALLEL ]] && MAX_PARALLEL=$SWARM_SIZE
fi
[[ -z "$WEB_MAX" ]] && WEB_MAX=3
# Exa is the default engine: it honours max_uses, reports the search count, and costs a flat
# ~$0.007 per search. Native engines may ignore the cap in reporting and cost several times more.
[[ -z "$WEB_ENGINE" ]] && WEB_ENGINE=exa

# web_search: off (default) | on | comma-separated phases, e.g. "architecture,review".
WEB_ON=false
case "$(echo "$WEB_RAW" | tr -d ' ')" in
  ""|off|false|no) ;;
  on|true|yes) WEB_ON=true ;;
  *) [[ ",$(echo "$WEB_RAW" | tr -d ' ')," == *",$PHASE,"* ]] && WEB_ON=true ;;
esac
# Azure's chat completions route has no web search tool, and sending an OpenRouter tool type
# there would be rejected. So the request is never sent with it: the run degrades to no-search
# instructions, and the header says why, so the director knows to verify claims itself.
WEB_UNAVAILABLE=""
if [[ "$WEB_ON" == "true" && "$PROVIDER" != "openrouter" ]]; then
  echo "WARNING: web_search is only available with provider openrouter; $PROVIDER experts run without it." >&2
  WEB_UNAVAILABLE="requested, but not available on $PROVIDER"
  WEB_ON=false
fi

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
validate_positive_int "max_parallel" "$MAX_PARALLEL"
if ! [[ "$QUORUM_PCT" =~ ^[0-9]+$ ]] || [[ "$QUORUM_PCT" -lt 1 || "$QUORUM_PCT" -gt 100 ]]; then
  echo "ERROR: quorum must be a percentage from 1 to 100, got '$QUORUM_PCT'" >&2
  exit 1
fi
if [[ "$GRACE_S" != "off" ]]; then
  validate_non_negative_int "grace" "$GRACE_S"
fi
case "$REASONING_EFFORT" in
  ""|minimal|low|medium|high) ;;
  *) echo "ERROR: reasoning_effort must be minimal, low, medium or high, got '$REASONING_EFFORT'" >&2; exit 1 ;;
esac
validate_positive_int "web_search_max" "$WEB_MAX"
case "$WEB_ENGINE" in
  exa|auto|native|parallel|perplexity) ;;
  *) echo "ERROR: web_search_engine must be exa, auto, native, parallel or perplexity, got '$WEB_ENGINE'" >&2; exit 1 ;;
esac
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

# ── Swarm angles ───────────────────────────────────────────────────
# Thousand Brains model: each cortical column builds a whole model of an object from its own
# patch of input. Here every swarm member reads the whole package but sees it through one angle,
# assigned by position, which replaces the dev style for that member; the director integrates
# the answers. Each angle is a character, not a topic: it gives the member a point of view.
angle_text() {
  case "$1" in
    security) echo "You are a penetration tester who has broken into systems like this one. You assume every input is hostile and every dependency can be compromised. Your angle: authentication, authorization, injection, secrets, and data exposure." ;;
    operations) echo "You are the on-call engineer who gets paged at 3am when this breaks. You have seen retries cause outages and silent failures go unnoticed for weeks. Your angle: partial failures, timeouts, observability, and recovery." ;;
    data) echo "You are a database engineer who has cleaned up after corrupted data and botched migrations. You trust nothing that is not idempotent. Your angle: data integrity, migrations, concurrency and races, and what gets lost." ;;
    performance) echo "You are a performance engineer who profiles before believing anything. You have seen designs that were fine at launch collapse at 10x. Your angle: latency, throughput, memory, hot paths, and growth." ;;
    simplicity) echo "You are a principal engineer who will maintain this for five years after its authors leave. Every moving part is a cost you will pay. Your angle: complexity, coupling, readability, and the cost of change." ;;
    product) echo "You are the product manager who answers to the users. You have watched technically sound features solve the wrong problem. Your angle: whether this solves the stated problem, for which users, and what users see when it fails." ;;
    testing) echo "You are a QA lead who believes only what a test proves. Your angle: how each behaviour would be verified, what is hard to test, and which success criterion has no test." ;;
    cost) echo "You are the engineer who owns the cloud bill and the dependency list. You have been burned by price changes, quotas and abandoned libraries. Your angle: money, lock-in, licensing, dependency health, and rate limits." ;;
    rollout) echo "You are a release engineer who has had to roll back at the worst moment. Your angle: migration path, backward compatibility, staged release, and how to undo this if it goes wrong." ;;
    contrarian) echo "You are a sharp outsider with no stake in this design and no patience for groupthink. Your angle: question the premise. Is this the right problem, what would a newcomer find odd, and what is the do-nothing or radically simpler alternative?" ;;
    *) echo "" ;;
  esac
}

if [[ "$SWARM_FLAG" == "true" ]]; then
  STYLES=("${_SWARM_ANGLES[@]}")
  for _AN in "${STYLES[@]}"; do
    if [[ -z "$(angle_text "$_AN")" ]]; then
      echo "ERROR: Unknown swarm angle '$_AN'. Expected security, operations, data, performance, simplicity, product, testing, cost, rollout, or contrarian" >&2
      exit 1
    fi
  done
  # Every seat needs its own angle: two seats with one angle (and, by default, one model) are
  # the same member asked twice, and their duplicate claims look like independent agreement.
  if [[ -n "$(printf '%s\n' "${STYLES[@]}" | sort | uniq -d)" ]]; then
    echo "ERROR: swarm_angles lists an angle twice: $(printf '%s\n' "${STYLES[@]}" | sort | uniq -d | tr '\n' ' ')" >&2
    exit 1
  fi
  if [[ "$SWARM_SIZE" -gt ${#STYLES[@]} ]]; then
    echo "ERROR: swarm_size $SWARM_SIZE is larger than the ${#STYLES[@]} swarm angles; each seat needs its own angle" >&2
    exit 1
  fi
fi

style_for_index() {
  if [[ ${#STYLES[@]} -eq 0 ]]; then
    echo "neutral"
  else
    echo "${STYLES[$(( $1 % ${#STYLES[@]} ))]}"
  fi
}

# Tells experts what searches are for. Without it models spend the budget on general knowledge
# they already have, instead of on facts that go stale.
# Without search the risk is the same (stale facts stated as current), so the experts are told
# to flag them rather than silently answer from training data.
if [[ "$WEB_ON" == "true" ]]; then
  WEB_ADDENDUM="WEB SEARCH: you can call the web_search tool at most ${WEB_MAX} times. Spend searches only on facts that go stale: current versions, whether a service, API or library still exists or is deprecated, current pricing and limits, recent breaking changes. Do not search for general engineering knowledge. Cite the URL inline for every claim that relies on a search. Mark claims about external products that you could not verify as (unverified)."
else
  WEB_ADDENDUM="NO WEB ACCESS: you cannot browse, and your knowledge has a cutoff. Mark every claim about current versions, whether a service, API or library still exists or is deprecated, or current pricing and limits as (unverified), and say what the operator should check. Prefer recommendations that do not depend on such facts."
fi

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
  # A swarm seat is identified by model and angle: each angle has one seat.
  local WEB_KEY="web=${WEB_ON}:${WEB_MAX}:${WEB_ENGINE}"
  # The style or angle wording is prepended per seat, outside SYSTEM_HASH: editing it must
  # not replay answers written under the old wording.
  local LENS="${STYLE}:${SWARM_FLAG}:${REASONING_EFFORT}:$(style_text "$STYLE")$(angle_text "$STYLE")"
  echo -n "${PROVIDER}|${PHASE}|${MODEL}|${LENS}|${WEB_KEY}|${TEMPERATURE}|${MAX_TOKENS}|${PROMPT_HASH}|${SYSTEM_HASH}" | shasum -a 256 2>/dev/null | cut -d' ' -f1 || \
    echo -n "${PROVIDER}|${PHASE}|${MODEL}|${LENS}|${WEB_KEY}|${TEMPERATURE}|${MAX_TOKENS}|${PROMPT_HASH}|${SYSTEM_HASH}" | md5 2>/dev/null
}

# Response file name for member IDX. One file per model keeps the familiar names; a list that
# repeats a model (always the case in a swarm) would overwrite itself, so it gets numbered seats.
member_file_base() {
  local IDX="$1" MODEL="$2" STYLE="$3"
  if [[ "$INDEXED_FILES" == "true" ]]; then
    printf '%02d_%s__%s' "$((IDX + 1))" "$(echo "$MODEL" | tr '/' '_')" "$STYLE"
  else
    echo "$MODEL" | tr '/' '_'
  fi
}

# ── Create output directory ────────────────────────────────────────
OUTPUT_DIR=$(mktemp -d)

# Track temp files for cleanup on exit/signal
_MOE_TEMP_FILES=()

# Stops a process and everything under it. The whole tree is listed first, then parents are
# stopped before children: a member whose curl died first could act on that (retry, sleep, or
# write FAILED) before being stopped itself.
kill_tree() {
  local pids=("$1") i=0 child
  while [[ $i -lt ${#pids[@]} ]]; do
    for child in $(pgrep -P "${pids[$i]}" 2>/dev/null); do
      pids+=("$child")
    done
    i=$((i + 1))
  done
  kill "${pids[@]}" 2>/dev/null || true
}

_moe_cleanup() {
  # Members still in flight (Ctrl-C, or this script killed) would otherwise keep running and billing.
  local pid
  for pid in $(jobs -p 2>/dev/null); do
    kill_tree "$pid"
  done
  if [[ ${#_MOE_TEMP_FILES[@]} -gt 0 ]]; then
    for f in "${_MOE_TEMP_FILES[@]}"; do
      rm -f "$f" 2>/dev/null
    done
  fi
  rm -f "$OUTPUT_DIR"/*.status "$OUTPUT_DIR"/*.cost "$OUTPUT_DIR"/*.part.md 2>/dev/null
}

trap _moe_cleanup EXIT
trap '_moe_cleanup; exit 130' INT
trap '_moe_cleanup; exit 143' TERM

echo "OUTPUT_DIR=$OUTPUT_DIR"

# Split models into array
IFS=',' read -ra MODELS <<< "$MODELS_RAW"

INDEXED_FILES="$SWARM_FLAG"
# Compared after the `/` -> `_` mapping, which can make two different names (a/b_c, a_b/c) collide.
if [[ "$INDEXED_FILES" == "false" ]] && \
   [[ -n "$(printf '%s\n' "${MODELS[@]}" | tr -d ' ' | tr '/' '_' | sort | uniq -d)" ]]; then
  INDEXED_FILES=true
fi

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
  challenge)
    # Deliberately adversarial: studies of LLM panels find that soft framing ("critique this",
    # "be a sceptic") produces agreement dressed up as nuance, while an explicit instruction to
    # oppose produces real objections. The director runs this on a design it is about to build.
    SYSTEM_PROMPT="You are a senior engineer assigned the role of opponent. A design has been chosen and is described in the package. You must oppose it. Your job is not to be balanced: assume the design is the wrong choice and make the strongest honest case against it, then show how it fails in practice. Do not hedge, do not restate its strengths, and do not propose a compromise unless the compromise is your actual recommendation. Never invent facts about the codebase; argue from what the package says and from how systems like this fail. Structure your response with these exact sections:

## Summary
2-3 sentences: the single strongest reason this design should not be built as described, and what you would do instead.

## The Case Against
The argument that this is the wrong choice. Attack the reasoning, the assumptions (including section 9), and the fit to the constraints. Prefer concrete failure paths over general concerns, and name the specific alternative you would choose instead and why it is better. Mark any point that depends on information the package does not contain.

## Post-Mortem
Six months have passed: the design shipped and failed. Write the short post-mortem. What broke, in what order, what the symptoms were, who noticed and how, and what the team wishes it had done differently. Be specific about the mechanism (load, data volume, concurrency, migration, cost, operational burden, a wrong assumption). This is about execution and consequences, not about the choice itself.

## Confidence
State HIGH, MEDIUM, or LOW confidence that these objections are decisive, with a one-sentence justification. If you would ultimately still build the design as described, say so plainly here. Then name the single piece of missing information that would most change this critique.

Every section is required.

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
State HIGH, MEDIUM, or LOW confidence in this response, with a one-sentence justification. Then name the single piece of missing information that would most change this answer, or write 'Nothing material.'.

Be specific. Every section is required.

IMPORTANT: Your response is limited to ${MAX_TOKENS} tokens. Be concise and prioritize the most valuable insights."
    ;;
esac

SYSTEM_HASH=$(printf '%s\n%s' "$SYSTEM_PROMPT" "$WEB_ADDENDUM" | shasum -a 256 2>/dev/null | cut -d' ' -f1 || echo "nohash")

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
      # Worst case includes every allowed search (Exa ~$0.007 each; other engines are priced
      # differently, so this is a floor for them).
      if [[ -n "$_MC" && "$WEB_ON" == "true" ]]; then
        _MC=$(echo "$_MC + 0.007 * $WEB_MAX" | bc -l)
      fi
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
  local STARTED=$SECONDS
  local HDR_FILE
  HDR_FILE=$(mktemp)
  local BASE_SYSTEM="$SYSTEM_PROMPT"
  local STYLE_LINE
  STYLE_LINE=$(style_text "$STYLE")
  if [[ "$SWARM_FLAG" == "true" ]]; then
    BASE_SYSTEM="YOUR CHARACTER: $(angle_text "$STYLE") This is your angle and your emphasis, not a blind spot: still cover every required section.

$SYSTEM_PROMPT"
  elif [[ -n "$STYLE_LINE" ]]; then
    BASE_SYSTEM="$STYLE_LINE Treat this as your emphasis, not a blind spot: still cover every required section.

$SYSTEM_PROMPT"
  fi
  if [[ -n "$WEB_ADDENDUM" ]]; then
    BASE_SYSTEM="$BASE_SYSTEM

$WEB_ADDENDUM"
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
      if [[ -n "$REASONING_EFFORT" ]]; then
        PAYLOAD=$(echo "$PAYLOAD" | jq --arg e "$REASONING_EFFORT" '. + {reasoning_effort: $e}')
      fi
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
      if [[ "$WEB_ON" == "true" ]]; then
        # max_uses is enforced server-side: past the cap the model is told the limit was hit.
        PAYLOAD=$(echo "$PAYLOAD" | jq --argjson max_uses "$WEB_MAX" --arg engine "$WEB_ENGINE" \
          '. + {tools: [{type: "openrouter:web_search", parameters: {max_uses: $max_uses, engine: $engine}}]}')
      fi
      if [[ -n "$REASONING_EFFORT" ]]; then
        # Reasoning models think before answering; lower effort trades depth for latency and cost.
        PAYLOAD=$(echo "$PAYLOAD" | jq --arg e "$REASONING_EFFORT" '. + {reasoning: {effort: $e}}')
      fi
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
      # With web search, models often narrate before calling the tool ("I'll verify X...") and
      # the answer is concatenated onto that sentence, leaving "...X.## Summary" mid-line where
      # neither the director nor a grep sees the heading. Put known section headings back on
      # their own line.
      CONTENT=$(echo "$BODY" | jq -r '.choices[0].message.content // empty
        | gsub("(?<pre>[^\n#])(?<h>## (Summary|Key Claims|Implementation Detail|Risks and Trade-offs|Clarifying Questions|Context Requests|Critical Issues|Warnings|Suggestions|Analysis|Alternatives Considered|Confidence)\\b)"; "\(.pre)\n\n\(.h)")')

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
      local SEARCHES="" SOURCES=""
      if [[ "$WEB_ON" == "true" ]]; then
        SEARCHES=$(echo "$BODY" | jq -r '.usage.server_tool_use_details.web_search_requests // 0' 2>/dev/null || echo 0)
        SOURCES=$(echo "$BODY" | jq -r '[.choices[0].message.annotations[]? | select(.type == "url_citation") | .url_citation]
          | unique_by(.url) | .[] | "- [\((.title // "") | gsub("[\\[\\]\n]"; " ") | if . == "" then "link" else . end)](\(.url))"' 2>/dev/null || true)
      fi

      {
        echo "# Response from $MODEL"
        echo ""
        echo "**Provider**: $PROVIDER"
        if [[ "$SWARM_FLAG" == "true" ]]; then
          echo "**Angle**: $STYLE"
        else
          echo "**Style**: $STYLE"
        fi
        if [[ "$WEB_ON" == "true" ]]; then
          echo "**Web searches**: $SEARCHES of $WEB_MAX ($WEB_ENGINE)"
        elif [[ -n "$WEB_UNAVAILABLE" ]]; then
          echo "**Web searches**: none ($WEB_UNAVAILABLE)"
        fi
        echo "**Tokens**: prompt=$USAGE_PROMPT, completion=$USAGE_COMPLETION"
        echo "**Attempts**: $((ATTEMPT + 1))$([[ "$EXPANDED" == "true" ]] && echo " (+1 with max_tokens=$TOKENS)")"
        echo "**Latency**: $((SECONDS - STARTED))s"
        [[ -n "$REASONING_EFFORT" ]] && echo "**Reasoning effort**: $REASONING_EFFORT"
        [[ "$PROVIDER" == "openrouter" ]] && printf '**Cost**: $%.4f\n' "$SPENT"
        [[ "$FINISH" == "length" ]] && echo "**Status**: TRUNCATED — cut off at max_tokens=$TOKENS; trailing sections may be missing"
        echo ""
        echo "---"
        echo ""
        echo "$CONTENT"
        if [[ -n "$SOURCES" ]]; then
          echo ""
          echo "## Web Sources"
          echo "$SOURCES"
        fi
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
MODEL_LIST=()
STYLE_LIST=()
FILE_LIST=()
PID_LIST=()
LAUNCH_LIST=()
RUN_STARTED=$SECONDS

for MODEL in "${MODELS[@]}"; do
  MODEL=$(echo "$MODEL" | tr -d ' ')
  IDX=${#MODEL_LIST[@]}
  STYLE=$(style_for_index "$IDX")
  FILE_BASE=$(member_file_base "$IDX" "$MODEL" "$STYLE")
  MODEL_LIST+=("$MODEL")
  STYLE_LIST+=("$STYLE")
  FILE_LIST+=("$FILE_BASE")
  OUTPUT_FILE="$OUTPUT_DIR/$FILE_BASE.md"
  RESULT_FILE="$OUTPUT_DIR/$FILE_BASE.status"
  KEY=$(cache_key "$MODEL" "$STYLE")

  # Check cache
  if [[ "$NO_CACHE" != "true" && -f "$CACHE_DIR/$KEY.md" ]]; then
    # The cached header's latency is the original request's, not this run's.
    sed 's/^\*\*Latency\*\*: \(.*\)$/**Latency**: \1 (original request; served from cache)/' \
      "$CACHE_DIR/$KEY.md" > "$OUTPUT_FILE"
    echo "CACHED" > "$RESULT_FILE"
    PID_LIST+=("")
    LAUNCH_LIST+=("")
    continue
  fi

  # At most MAX_PARALLEL requests in flight; the next starts as soon as any one finishes. Bash 3.2
  # (macOS) has no `wait -n`, so it polls the count of running jobs; the final loop reaps them all.
  while [[ $(jobs -rp | wc -l) -ge $MAX_PARALLEL ]]; do
    sleep 0.2
  done

  (
    # The answer is written under a temporary name and published after its status, so a member
    # with no status file has not finished and dropping it late never discards a finished answer.
    PART_FILE="$OUTPUT_DIR/$FILE_BASE.part.md"
    RESULT=$(call_model "$MODEL" "$PART_FILE" "$STYLE")
    echo "$RESULT" > "$RESULT_FILE"
    [[ -f "$PART_FILE" ]] && mv "$PART_FILE" "$OUTPUT_FILE"
    # Cache complete answers only; a TRUNCATED one would be replayed forever. Two seats can share
    # a cache key, so each writes its own temporary file.
    if [[ "$RESULT" == "OK" && "$NO_CACHE" != "true" ]]; then
      CACHE_TMP=$(mktemp "$CACHE_DIR/.$KEY.XXXXXX")
      cp "$OUTPUT_FILE" "$CACHE_TMP"
      mv "$CACHE_TMP" "$CACHE_DIR/$KEY.md"
    fi
  ) &
  PID_LIST+=($!)
  LAUNCH_LIST+=($SECONDS)
done

# Wait for the members: all of them, or quorum + grace (see QUORUM_PCT above). The quorum counts
# live members that returned an answer. Cached members are left out (they answer at once, so a
# re-run would start the clock at zero and drop the same slow member again), and so are failures
# (two quick errors must not cut short the one member still working).
answered_count() {
  local i n=0 s
  for (( i = 0; i < TOTAL_MEMBERS; i++ )); do
    [[ -z "${PID_LIST[$i]}" ]] && continue
    s=$(cat "$OUTPUT_DIR/${FILE_LIST[$i]}.status" 2>/dev/null || true)
    [[ "$s" == "OK" || "$s" == "TRUNCATED" ]] && n=$((n + 1))
  done
  echo "$n"
}

# Once quorum is reached, every member's budget is the time the quorum took plus the grace,
# counted from that member's own launch: a member that waited for a free slot (MAX_PARALLEL
# below the member count) started late, which does not make it slow.
still_in_budget() {
  local i
  for (( i = 0; i < TOTAL_MEMBERS; i++ )); do
    [[ -z "${PID_LIST[$i]}" || -f "$OUTPUT_DIR/${FILE_LIST[$i]}.status" ]] && continue
    [[ $(( SECONDS - LAUNCH_LIST[i] )) -lt $BUDGET_S ]] && return 0
  done
  return 1
}

TOTAL_MEMBERS=${#MODEL_LIST[@]}
LIVE_MEMBERS=0
for PID in "${PID_LIST[@]}"; do
  [[ -n "$PID" ]] && LIVE_MEMBERS=$((LIVE_MEMBERS + 1))
done
BUDGET_S=""
QUORUM_AT=0
QUORUM_S=0
while [[ $(jobs -rp | wc -l) -gt 0 ]]; do
  if [[ "$GRACE_S" != "off" && $LIVE_MEMBERS -gt 1 ]]; then
    ANSWERED=$(answered_count)
    if [[ -z "$BUDGET_S" && $(( ANSWERED * 100 )) -ge $(( QUORUM_PCT * LIVE_MEMBERS )) ]]; then
      QUORUM_AT=$ANSWERED
      QUORUM_S=$(( SECONDS - RUN_STARTED ))
      BUDGET_S=$(( QUORUM_S + GRACE_S ))
      [[ $ANSWERED -lt $LIVE_MEMBERS ]] && \
        echo "  Quorum: $ANSWERED of $LIVE_MEMBERS live members answered in ${QUORUM_S}s; waiting up to ${GRACE_S}s more for the rest..." >&2
    fi
    [[ -n "$BUDGET_S" ]] && ! still_in_budget && break
  fi
  sleep 0.5
done

# Drop the members still running when their budget ran out. Their requests are cancelled; the
# provider may still bill tokens it generated before the cancel, which is not counted below.
# Without a quorum the loop above ran until every member finished, so there is nothing to drop.
if [[ -n "$BUDGET_S" ]]; then
  for (( _MI = 0; _MI < TOTAL_MEMBERS; _MI++ )); do
    PID="${PID_LIST[$_MI]}"
    FILE_BASE="${FILE_LIST[$_MI]}"
    PART_FILE="$OUTPUT_DIR/$FILE_BASE.part.md"
    [[ -z "$PID" || -f "$OUTPUT_DIR/$FILE_BASE.status" ]] && continue
    # A member that exited without a status crashed rather than ran late; the summary reports it.
    jobs -rp | grep -qx "$PID" || continue
    kill_tree "$PID"
    wait "$PID" 2>/dev/null || true
    # It may have finished between the check and the kill; then its answer stands.
    if [[ -f "$OUTPUT_DIR/$FILE_BASE.status" ]]; then
      [[ -f "$PART_FILE" ]] && mv "$PART_FILE" "$OUTPUT_DIR/$FILE_BASE.md"
      continue
    fi
    rm -f "$PART_FILE"
    {
      echo "# LATE from ${MODEL_LIST[$_MI]}"
      echo ""
      echo "**Status**: LATE — no answer after $(( SECONDS - LAUNCH_LIST[_MI] ))s. $QUORUM_AT of $LIVE_MEMBERS live members had answered within ${QUORUM_S}s, and each member gets that plus ${GRACE_S}s; dropped so the run could finish."
      echo ""
      echo "Raise \`grace\` (or \`swarm_grace\`), or set it to \`off\`, to wait for every member."
    } > "$OUTPUT_DIR/$FILE_BASE.md"
    echo "LATE" > "$OUTPUT_DIR/$FILE_BASE.status"
    echo "  Dropped late: ${MODEL_LIST[$_MI]} ($FILE_BASE)" >&2
  done
fi
for PID in "${PID_LIST[@]}"; do
  [[ -n "$PID" ]] && { wait "$PID" 2>/dev/null || true; }
done

# ── Fallback: retry failed models with alternatives ────────────────
FALLBACK_IDX=0
_MI=0
for MODEL in "${MODEL_LIST[@]}"; do
  STYLE="${STYLE_LIST[$_MI]}"
  FILE_BASE="${FILE_LIST[$_MI]}"
  _MI=$((_MI + 1))
  STATUS_FILE="$OUTPUT_DIR/$FILE_BASE.status"
  STATUS=$(cat "$STATUS_FILE" 2>/dev/null || echo "FAILED")

  if [[ "$STATUS" == "FAILED" && $FALLBACK_IDX -lt ${#FALLBACKS[@]} ]]; then
    FALLBACK_MODEL=$(echo "${FALLBACKS[$FALLBACK_IDX]}" | tr -d ' ')
    FALLBACK_IDX=$((FALLBACK_IDX + 1))
    OUTPUT_FILE="$OUTPUT_DIR/$FILE_BASE.md"

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
LATE_COUNT=0

_MI=0
for MODEL in "${MODEL_LIST[@]}"; do
  FILE_BASE="${FILE_LIST[$_MI]}"
  _MI=$((_MI + 1))
  OUTPUT_FILE="$OUTPUT_DIR/$FILE_BASE.md"
  STATUS_FILE="$OUTPUT_DIR/$FILE_BASE.status"
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
    LATE)
      echo "  LATE  $OUTPUT_FILE"
      LATE_COUNT=$((LATE_COUNT + 1))
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
LATE_STR=""
[[ $LATE_COUNT -gt 0 ]] && LATE_STR=", $LATE_COUNT dropped late"
echo "SUMMARY: $SUCCESS_COUNT succeeded${NOTE_STR}, $FAIL_COUNT failed${LATE_STR}, ${#MODEL_LIST[@]} total${COST_STR}"
