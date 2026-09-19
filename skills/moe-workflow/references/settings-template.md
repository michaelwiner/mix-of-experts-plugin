# Settings Template

## Where the file lives

Agents pick the first file that exists and pass it as `--settings-file`. The scripts
themselves never search.

1. `<project>/.cursor/mix-of-experts.local.md`
2. `~/.cursor/mix-of-experts.local.md`
3. `<project>/.claude/mix-of-experts-plugin.local.md`
4. `~/.claude/mix-of-experts-plugin.local.md`

All four are `*.local.md` files: keep them out of git.

## API keys (environment only)

| Provider | Variables |
|---|---|
| `openrouter` (default) | `OPENROUTER_API_KEY` |
| `azure-foundry` | `AZURE_OPENAI_API_KEY` (or its alias `AZURE_OPENAI_KEY`) and `AZURE_OPENAI_ENDPOINT` |

```bash
export OPENROUTER_API_KEY=sk-or-v1-your-key-here
# or
export AZURE_OPENAI_API_KEY=your-foundry-key
export AZURE_OPENAI_ENDPOINT=https://YOUR-RESOURCE.services.ai.azure.com
```

The settings file can also hold `openrouter_api_key` / `azure_api_key`, but the env var always
wins and is the only way that cannot leak through a commit.

A settings file is optional for OpenRouter when `OPENROUTER_API_KEY` is set (the default
models are used). Azure always needs one, because `models:` has no default.

## Azure AI Foundry

```markdown
---
provider: azure-foundry
azure_endpoint: https://YOUR-RESOURCE.services.ai.azure.com
models: grok-4.6-expert,DeepSeek-V4-Pro-expert,gpt-5.6-sol
max_tokens: 8000
temperature: 0.3
timeout: 300
retries: 1
---
```

- `models` are **deployment names** from your Foundry resource, not OpenRouter IDs. Required.
- Requests go to `{endpoint}/openai/v1/chat/completions` with an `api-key` header.
- `max_tokens` is sent as `max_completion_tokens`. `temperature` is validated but **not sent**,
  because GPT-5.x Foundry deployments reject non-default temperatures.
- No per-call cost lookup (that endpoint is OpenRouter-only).

## OpenRouter

```markdown
---
provider: openrouter
models: openai/gpt-5.2,google/gemini-3-flash-preview,deepseek/deepseek-v3.2-20251201
fallback_models: meta-llama/llama-3.3-70b,mistralai/mistral-large
max_tokens: 8000
temperature: 0.3
timeout: 300
retries: 1
---

## Notes

Any markdown content below the frontmatter is ignored by the script.
```

`provider: openrouter` may be omitted: it is the default.

## Available Fields

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `provider` | No | `openrouter` | `openrouter` or `azure-foundry` |
| `models` | Azure: yes | OpenRouter: `openai/gpt-5.2,google/gemini-3-flash-preview,deepseek/deepseek-v3.2-20251201` | Comma-separated. OpenRouter IDs (`provider/model`) or Foundry deployment names |
| `azure_endpoint` | Azure: yes, unless `AZURE_OPENAI_ENDPOINT` is set | - | Foundry resource URL; a trailing `/` is stripped |
| `openrouter_api_key` / `azure_api_key` | No | - | Fallbacks for the env vars; prefer the env |
| `fallback_models` | No | - | Same format as `models`; used when a primary model fails after all retries |
| `max_tokens` | No | `8000` | Maximum completion tokens per model |
| `temperature` | No | `0.3` | 0.0 – 2.0. Ignored (not sent) for `azure-foundry` |
| `timeout` | No | `300` | Max seconds per API call |
| `retries` | No | `1` | Retries on empty response, 429, 5xx and network errors (so 2 attempts by default) |

## Finding model IDs

- OpenRouter: https://openrouter.ai/models (e.g. `openai/gpt-5.2`, `google/gemini-3-pro-preview`)
- Foundry: the **Deployments** page of your Azure AI Foundry project

## Example OpenRouter combinations

**Balanced (default)**:
```
models: openai/gpt-5.2,google/gemini-3-flash-preview,deepseek/deepseek-v3.2-20251201
```

**Budget-friendly**:
```
models: google/gemini-3-flash-preview,deepseek/deepseek-v3.2-20251201
```

**Maximum coverage**:
```
models: openai/gpt-5.2,google/gemini-3-pro-preview,deepseek/deepseek-v3.2-20251201,mistralai/mistral-large
```
