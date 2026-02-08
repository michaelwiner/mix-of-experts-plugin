#!/bin/bash
# validate-setup.sh - Pre-flight validation for Mix of Experts plugin
# Called by SessionStart hook. Always exits 0 to never block Claude from starting.

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
if command -v jq &>/dev/null; then
  HOOK_INPUT=$(cat 2>/dev/null || true)
  if [[ -n "$HOOK_INPUT" ]]; then
    PARSED_CWD=$(echo "$HOOK_INPUT" | jq -r '.cwd // empty' 2>/dev/null)
    [[ -n "$PARSED_CWD" ]] && CWD="$PARSED_CWD"
  fi
fi

# ── Locate settings file ────────────────────────────────────────
SETTINGS_FILE=""
if [[ -f "$CWD/.claude/mix-of-experts-plugin.local.md" ]]; then
  SETTINGS_FILE="$CWD/.claude/mix-of-experts-plugin.local.md"
elif [[ -f "$HOME/.claude/mix-of-experts-plugin.local.md" ]]; then
  SETTINGS_FILE="$HOME/.claude/mix-of-experts-plugin.local.md"
fi

if [[ -z "$SETTINGS_FILE" ]]; then
  if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
    WARNINGS+=("No API key found. Set OPENROUTER_API_KEY env var or create .claude/mix-of-experts-plugin.local.md with your key.")
  fi
else
  # Validate YAML frontmatter
  FRONTMATTER=$(sed -n '/^---$/,/^---$/p' "$SETTINGS_FILE" 2>/dev/null | sed '1d;$d')

  if [[ -z "$FRONTMATTER" ]]; then
    WARNINGS+=("Settings file found but has no YAML frontmatter (missing --- delimiters).")
  else
    # Check for API key: env var takes priority, then settings file
    API_KEY="${OPENROUTER_API_KEY:-}"
    if [[ -z "$API_KEY" ]]; then
      API_KEY=$(echo "$FRONTMATTER" | grep '^openrouter_api_key:' | sed 's/^openrouter_api_key: *//' | tr -d '"' | tr -d "'")
    fi
    if [[ -z "$API_KEY" ]]; then
      WARNINGS+=("No API key found. Set OPENROUTER_API_KEY env var or add openrouter_api_key to settings file.")
    elif [[ ! "$API_KEY" =~ ^sk-or- ]]; then
      WARNINGS+=("API key does not start with 'sk-or-' — it may be invalid.")
    fi
  fi
fi

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
