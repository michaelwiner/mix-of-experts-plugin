#!/bin/bash
# validate-setup.sh - Pre-flight validation for Mix of Experts plugin
# Called by the SessionStart hook, and by the skills at the start of a workflow (the hook does
# not fire reliably for every install type). Always exits 0 to never block anything.
# Manual use: bash validate-setup.sh < /dev/null

ERRORS=()
WARNINGS=()

# ── Check required dependencies ──────────────────────────────────
for cmd in curl jq bc; do
  if ! command -v "$cmd" &>/dev/null; then
    ERRORS+=("Missing dependency: '$cmd'. Install with: brew install $cmd")
  fi
done

# ── Determine working directory from hook input ──────────────────
CWD="$(pwd)"
if command -v jq &>/dev/null && [[ ! -t 0 ]]; then
  HOOK_INPUT=$(cat 2>/dev/null || true)
  if [[ -n "$HOOK_INPUT" ]]; then
    PARSED_CWD=$(echo "$HOOK_INPUT" | jq -r '.cwd // empty' 2>/dev/null)
    [[ -n "$PARSED_CWD" ]] && CWD="$PARSED_CWD"
  fi
fi

# ── Locate settings file ────────────────────────────────────────
# Same search order the skills use: Cursor project, Cursor user, then the Claude variants.
SETTINGS_FILE=""
for CANDIDATE in \
  "$CWD/.cursor/mix-of-experts.local.md" \
  "$HOME/.cursor/mix-of-experts.local.md" \
  "$CWD/.claude/mix-of-experts-plugin.local.md" \
  "$HOME/.claude/mix-of-experts-plugin.local.md"; do
  if [[ -f "$CANDIDATE" ]]; then
    SETTINGS_FILE="$CANDIDATE"
    break
  fi
done

AZURE_ENV_KEY="${AZURE_OPENAI_API_KEY:-${AZURE_OPENAI_KEY:-}}"

FRONTMATTER=""
if [[ -n "$SETTINGS_FILE" ]]; then
  FRONTMATTER=$(sed -n '/^---$/,/^---$/p' "$SETTINGS_FILE" 2>/dev/null | sed '1d;$d')
  if [[ -z "$FRONTMATTER" ]]; then
    WARNINGS+=("Settings file $SETTINGS_FILE has no YAML frontmatter (missing --- delimiters).")
  fi
fi

get_setting() {
  [[ -n "$FRONTMATTER" ]] || return 0
  echo "$FRONTMATTER" | grep "^$1:" | head -1 | sed "s/^$1: *//" | tr -d '"' | tr -d "'"
}

PROVIDER=$(get_setting provider)
[[ -z "$PROVIDER" ]] && PROVIDER="openrouter"

case "$PROVIDER" in
  openrouter)
    API_KEY="${OPENROUTER_API_KEY:-}"
    [[ -z "$API_KEY" ]] && API_KEY=$(get_setting openrouter_api_key)
    if [[ -z "$API_KEY" ]]; then
      if [[ -z "$SETTINGS_FILE" ]]; then
        WARNINGS+=("No API key found. Set OPENROUTER_API_KEY env var or create a settings file (see the plugin README).")
      else
        WARNINGS+=("No API key found. Set OPENROUTER_API_KEY env var or add openrouter_api_key to $SETTINGS_FILE.")
      fi
    elif [[ ! "$API_KEY" =~ ^sk-or- ]]; then
      WARNINGS+=("API key does not start with 'sk-or-' — it may be invalid.")
    fi
    ;;
  azure-foundry)
    API_KEY="$AZURE_ENV_KEY"
    [[ -z "$API_KEY" ]] && API_KEY=$(get_setting azure_api_key)
    [[ -z "$API_KEY" ]] && WARNINGS+=("azure-foundry: no key. Set AZURE_OPENAI_API_KEY (or AZURE_OPENAI_KEY).")
    ENDPOINT="${AZURE_OPENAI_ENDPOINT:-}"
    [[ -z "$ENDPOINT" ]] && ENDPOINT=$(get_setting azure_endpoint)
    [[ -z "$ENDPOINT" ]] && WARNINGS+=("azure-foundry: no endpoint. Set AZURE_OPENAI_ENDPOINT or azure_endpoint in $SETTINGS_FILE.")
    if [[ -z "$(get_setting models)" ]] && ! echo "$FRONTMATTER" | grep -q '^models_[a-z-]*:'; then
      WARNINGS+=("azure-foundry: 'models:' (Foundry deployment names) is required in $SETTINGS_FILE.")
    fi
    ;;
  *)
    WARNINGS+=("Unknown provider '$PROVIDER' in $SETTINGS_FILE. Expected: openrouter or azure-foundry.")
    ;;
esac

# ── Output results ───────────────────────────────────────────────
if [[ ${#ERRORS[@]} -eq 0 && ${#WARNINGS[@]} -eq 0 ]]; then
  echo "[MoE Plugin] Setup OK: all dependencies found, settings loaded."
  exit 0
fi

# Build message
MSG="[MoE Plugin] Setup issues detected:\\n"
for E in "${ERRORS[@]}"; do
  MSG+="  ERROR: $E\\n"
done
for W in "${WARNINGS[@]}"; do
  MSG+="  WARNING: $W\\n"
done

# Emit as systemMessage JSON if jq is available, otherwise plain text
if command -v jq &>/dev/null; then
  echo "$MSG" | jq -Rs '{ systemMessage: . }'
else
  echo -e "$MSG"
fi

exit 0
