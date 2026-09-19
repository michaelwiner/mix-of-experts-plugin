#!/bin/bash
# sync-cursor-skill.sh - Install the Cursor skill by symlinking ~/.cursor/skills/moe-workflow
# to this clone's cursor/moe-workflow, and seed a settings file if none exists.
# Re-run any time; a symlink means `git pull` updates the installed skill in place.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SOURCE="$REPO_ROOT/cursor/moe-workflow"
TARGET="$HOME/.cursor/skills/moe-workflow"
SETTINGS="$HOME/.cursor/mix-of-experts.local.md"

for REQUIRED in "$SOURCE/SKILL.md" "$SOURCE/scripts/query-models.sh"; do
  if [[ ! -e "$REQUIRED" ]]; then
    echo "ERROR: $REQUIRED is missing. Run this from a complete clone of mix-of-experts-plugin." >&2
    exit 1
  fi
done

# Never clobber a real directory: it may be a hand-edited copy someone wants to keep.
if [[ -e "$TARGET" && ! -L "$TARGET" ]]; then
  echo "ERROR: $TARGET exists and is not a symlink. Move it aside, then re-run." >&2
  exit 1
fi

mkdir -p "$(dirname "$TARGET")"
ln -sfn "$SOURCE" "$TARGET"
echo "Linked $TARGET -> $SOURCE"

# Seed only when missing; the user's file is theirs. Keys stay in the env, never in this file.
if [[ ! -f "$SETTINGS" ]]; then
  # Seed the provider whose key is actually present, so the first run works out of the box.
  if [[ -n "${OPENROUTER_API_KEY:-}" && -z "${AZURE_OPENAI_API_KEY:-}${AZURE_OPENAI_KEY:-}" ]]; then
    SEED_PROVIDER="openrouter"
    SEED_MODELS="openai/gpt-5.6-sol,google/gemini-3.8-flash,x-ai/grok-4.6"
  else
    SEED_PROVIDER="azure-foundry"
    SEED_MODELS="grok-4.6-expert,DeepSeek-V4-Pro-expert,gpt-5.6-sol"
  fi
  cat > "$SETTINGS" <<SETTINGS_EOF
---
provider: $SEED_PROVIDER
models: $SEED_MODELS
max_tokens: 8000
temperature: 0.3
timeout: 300
retries: 1
---

Mix of Experts settings for Cursor. Secrets come from the environment:
AZURE_OPENAI_API_KEY (or AZURE_OPENAI_KEY) and AZURE_OPENAI_ENDPOINT for azure-foundry,
OPENROUTER_API_KEY for openrouter. Switch by changing provider and models together
(Foundry deployment names, or OpenRouter IDs such as openai/gpt-5.6-sol).
SETTINGS_EOF
  chmod 600 "$SETTINGS"
  echo "Seeded $SETTINGS (edit models/provider to taste)"
else
  echo "Kept existing $SETTINGS"
fi
