#!/bin/bash
# smoke-azure-foundry.sh - Live end-to-end check of the azure-foundry provider.
# Usage: AZURE_OPENAI_ENDPOINT=https://<resource>.services.ai.azure.com \
#        AZURE_OPENAI_API_KEY=... [AZURE_DEPLOYMENTS=a,b,c] bash smoke-azure-foundry.sh
# Exit: 0 = at least one deployment answered, 1 = failed, 2 = skipped (no credentials).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# Accept either env name, the same way query-models.sh does.
if [[ -z "${AZURE_OPENAI_API_KEY:-}" && -n "${AZURE_OPENAI_KEY:-}" ]]; then
  export AZURE_OPENAI_API_KEY="$AZURE_OPENAI_KEY"
fi

if [[ -z "${AZURE_OPENAI_API_KEY:-}" || -z "${AZURE_OPENAI_ENDPOINT:-}" ]]; then
  echo "SKIP: set AZURE_OPENAI_API_KEY (or AZURE_OPENAI_KEY) and AZURE_OPENAI_ENDPOINT to run the Azure smoke test." >&2
  exit 2
fi

DEPLOYMENTS="${AZURE_DEPLOYMENTS:-grok-4.6-expert,DeepSeek-V4-Pro-expert,gpt-5.6-sol}"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# Key and endpoint stay in the env; the temp file never holds a secret.
cat > "$WORK_DIR/settings.local.md" <<SETTINGS
---
provider: azure-foundry
models: $DEPLOYMENTS
max_tokens: 512
retries: 1
---
SETTINGS

cat > "$WORK_DIR/prompt.md" <<'PROMPT'
This is an automated smoke test of the Mix of Experts Azure Foundry provider.
Put the exact token SMOKE_OK in your Summary section, and keep every section to one line.
PROMPT

OUTPUT=$(bash "$SCRIPT_DIR/query-models.sh" \
  --settings-file "$WORK_DIR/settings.local.md" \
  --phase ad-hoc \
  --prompt-file "$WORK_DIR/prompt.md" \
  --no-cache 2>&1) || true
echo "$OUTPUT"

if echo "$OUTPUT" | grep -qE 'SUMMARY: [1-9][0-9]* succeeded'; then
  echo "SMOKE: PASS"
  exit 0
fi
echo "SMOKE: FAIL (no deployment succeeded)" >&2
exit 1
