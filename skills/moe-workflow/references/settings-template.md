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
- Requests go to `{endpoint}/openai/v1/chat/completions` with an `api-key` header. Use the
  **resource** endpoint (`https://<resource>.services.ai.azure.com` or
  `https://<resource>.openai.azure.com`); a pasted `/openai/v1` suffix is stripped. Project
  endpoints (`.../api/projects/<name>`) are documented for Entra ID tokens and usually reject
  API keys, so the scripts warn about them.
- Content-filtered answers (`finish_reason: content_filter`) fail immediately as
  `CONTENT_FILTERED` and are not retried: the same prompt would be blocked again.
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
| `models_<phase>` | No | - | Overrides `models` for one round, e.g. `models_clarify:` with cheaper models. Phases: `clarify`, `architecture`, `review`, `ad-hoc` |
| `fallback_models` | No | - | Same format as `models`; used when a primary model fails after all retries |
| `styles` | No | `ship,scale,simplify` | Professional lens per expert, assigned by model position and rotating. Values: `ship`, `scale`, `simplify`, `neutral`, or `off` |
| `web_search` | No | `off` | `on`, `off`, or phases, e.g. `architecture,review`. Lets experts search the web (OpenRouter only) |
| `web_search_max` | No | `3` | Maximum searches per expert per call (enforced by OpenRouter) |
| `web_search_engine` | No | `exa` | `exa`, `auto`, `native`, `parallel`, `perplexity` |
| `max_cost_usd` | No | `1` | Pre-run estimate above this blocks the run (exit 3) until re-run with `--confirm-cost`. OpenRouter only |
| `max_tokens` | No | `8000` | Maximum completion tokens per model |
| `temperature` | No | `0.3` | 0.0 – 2.0. Ignored (not sent) for `azure-foundry` |
| `timeout` | No | `300` | Max seconds per API call |
| `retries` | No | `1` | Retries on empty response, 429, 5xx and network errors (so 2 attempts by default) |

## Dev styles

Three experts given identical instructions tend to converge on the same answer. By default
each expert gets one professional lens, in model order:

| Style | Lens |
|---|---|
| `ship` | Pragmatic startup engineer: simplest design that ships safely now; flags over-engineering |
| `scale` | Staff/SRE engineer: failure modes, concurrency, data integrity, observability, 10x load |
| `simplify` | Principal maintainer: clear boundaries, few moving parts, readability, long-term cost |
| `neutral` | No lens |

The lens is an emphasis: every expert still returns every required section. `styles: off`
disables it. The style is recorded in each response header (`**Style**:`).

## Web search

Experts have no web access by default, so they answer from training data and can recommend
services that no longer exist or quote old versions. With `web_search` on, each expert can call
OpenRouter's web search tool up to `web_search_max` times (default 3; the cap is enforced
server-side, past it the model is told the limit was hit) and must cite URLs for searched claims
and mark unverifiable product claims `(unverified)`.

```markdown
---
web_search: architecture,review
web_search_max: 3
---
```

- **Recommended rounds:** `architecture` and `review`. `clarify` rarely needs it.
- **Cost:** the Exa engine is about $0.007 per search, so at most ~$0.02 per expert per call
  with the default cap; it is included in the pre-run estimate and the actual `Cost:` line.
- **Privacy:** experts write their own search queries from the package, so fragments of it can
  reach the search provider. Leave it off for confidential work.
- **Engine:** `exa` (default) reports the search count reliably. `native` uses the model
  provider's own search, which can cost several times more.
- **Azure Foundry:** its chat completions route has no web search tool, so the request is never
  sent with one (no API error). The run warns once, headers read
  `**Web searches**: none (requested, but not available on azure-foundry)`, and experts get the
  no-search instructions below.
- **Without search** (the default, or Azure) experts are told they have no web access and must
  mark claims about current versions, availability, or pricing `(unverified)` with what to check;
  the director verifies those before the synthesis.

## Cheaper clarify rounds

```markdown
---
models: openai/gpt-5.2,google/gemini-3-pro-preview,deepseek/deepseek-v3.2-20251201
models_clarify: google/gemini-3-flash-preview,deepseek/deepseek-v3.2-20251201,openai/gpt-5-mini
---
```

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
