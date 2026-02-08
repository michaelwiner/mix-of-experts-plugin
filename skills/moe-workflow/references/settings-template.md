# Settings Template

## API Key (Required)

Set your OpenRouter API key as an environment variable (recommended):

```bash
export OPENROUTER_API_KEY=sk-or-v1-your-key-here
```

This is the safest approach — the key never touches any file that could be committed to git.

## Settings File (Optional)

Create at `.claude/mix-of-experts-plugin.local.md` in your project root (or `~/.claude/mix-of-experts-plugin.local.md` for global config).

## Minimal Configuration

```markdown
---
models: openai/gpt-5.2,google/gemini-3-flash-preview,deepseek/deepseek-v3.2-20251201
---
```

This uses the default models: GPT-5.2, Gemini 3 Flash Preview, Deepseek V3.2. The API key can also be set here as `openrouter_api_key` but the env var is preferred.

## Full Configuration

```markdown
---
openrouter_api_key: sk-or-v1-your-key-here
models: openai/gpt-5.2,google/gemini-3-flash-preview,deepseek/deepseek-v3.2-20251201
fallback_models: meta-llama/llama-3.3-70b,mistralai/mistral-large
max_tokens: 8192
temperature: 0.3
timeout: 300
retries: 2
---

## Notes

Any markdown content below the frontmatter is ignored by the script.
Use this space for personal notes about model preferences or project-specific configuration.
```

## Available Fields

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `openrouter_api_key` | No | - | Your OpenRouter API key (env var `OPENROUTER_API_KEY` is preferred) |
| `models` | No | `openai/gpt-5.2,google/gemini-3-flash-preview,deepseek/deepseek-v3.2-20251201` | Comma-separated list of OpenRouter model IDs |
| `fallback_models` | No | - | Comma-separated fallback models used when primary models fail after all retries |
| `max_tokens` | No | `8192` | Maximum tokens per model response |
| `temperature` | No | `0.3` | Sampling temperature (0.0 - 2.0). Lower = more deterministic. |
| `timeout` | No | `300` | Max seconds to wait per API call |
| `retries` | No | `2` | Number of retry attempts on failure (429, 5xx, network errors) |

## Finding Model IDs

Browse available models at https://openrouter.ai/models. The model ID is shown on each model's page (e.g., `openai/gpt-5.2`, `google/gemini-3-pro-preview`).

## Example Model Combinations

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
