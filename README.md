# Mix of Experts

A Claude Code plugin that consults multiple AI models as expert advisors during feature development. Opus orchestrates GPT, Gemini, Deepseek (and others) through OpenRouter, gathering diverse architectural opinions and code reviews at key decision points.

## Overview

Instead of relying on a single model's perspective, Mix of Experts fans out prompts to multiple LLMs in parallel and synthesizes their responses into structured comparison reports. The plugin integrates into a 7-phase feature development workflow with two primary consultation points: architecture design and code review.

## Prerequisites

- [Claude Code](https://claude.ai/claude-code) installed
- An [OpenRouter](https://openrouter.ai/) API key (get one at https://openrouter.ai/keys)
- `curl` and `jq` installed (`brew install curl jq` on macOS)
- Bash 4+ (macOS ships with an older version; `brew install bash` if needed)

## Installation

```bash
claude plugin add /path/to/mix_of_experts_plugin
```

## Setup

Create a settings file at `.claude/mix-of-experts-plugin.local.md` in your project root:

```markdown
---
openrouter_api_key: sk-or-v1-your-key-here
---
```

This minimal config uses the default models (GPT-5.2, Gemini 3 Flash Preview, Deepseek V3.2). See [Configuration Reference](#configuration-reference) below for all options.

For a global config that applies to all projects, place the file at `~/.claude/mix-of-experts-plugin.local.md` instead. Project-level settings take precedence.

> **Note**: The `.claude/*.local.md` pattern is gitignored by default, so your API key stays out of version control.

## Usage

Start the workflow with the `/moe` slash command:

```
/moe Add a real-time notification system using WebSockets
```

This kicks off a 7-phase workflow:

1. **Discovery** -- Understand the feature requirements
2. **Codebase Exploration** -- Analyze relevant existing code and patterns
3. **Clarifying Questions** -- Resolve ambiguities before designing
4. **Architecture Design (MoE)** -- Fan out to all configured models for diverse architectural proposals, then synthesize into a comparison report
5. **Implementation** -- Build the feature following the chosen architecture
6. **Quality Review (MoE)** -- Fan out to all models for code review, then synthesize findings with multi-model agreement highlighted
7. **Summary** -- Document what was built and key decisions

### Ad-hoc consultation

Outside the main workflow, you can ask for multi-model input at any time by requesting it during a conversation. The plugin supports an `ad-hoc` consultation phase for one-off technical questions.

## How It Works

When a consultation phase runs:

1. Opus prepares a detailed prompt with feature context and codebase findings
2. The prompt is sent to all configured models **in parallel** via the OpenRouter API
3. Each model responds with structured sections (e.g., Summary, Key Claims, Risks)
4. Opus reads all responses and synthesizes them into a comparison report, highlighting:
   - **Consensus**: where models independently agree (strong signal)
   - **Disagreements**: where models differ, with analysis of which argument is stronger
   - **Unique insights**: ideas from a single model worth considering
   - **Risk summary**: ordered by how many models flagged each risk

## Configuration Reference

All settings go in the YAML frontmatter of your `.claude/mix-of-experts-plugin.local.md` file.

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `openrouter_api_key` | Yes | -- | Your OpenRouter API key (starts with `sk-or-`) |
| `models` | No | `openai/gpt-5.2,google/gemini-3-flash-preview,deepseek/deepseek-v3.2-20251201` | Comma-separated OpenRouter model IDs |
| `fallback_models` | No | -- | Comma-separated fallback models used when primary models fail after all retries |
| `max_tokens` | No | `4096` | Maximum tokens per model response |
| `temperature` | No | `0.3` | Sampling temperature (0.0--2.0). Lower = more deterministic |
| `timeout` | No | `300` | Max seconds to wait per API call |
| `retries` | No | `2` | Retry attempts on failure (429, 5xx, network errors) |

### Example model combinations

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

Browse all available models at https://openrouter.ai/models.

## Troubleshooting

**"openrouter_api_key not found in settings file"**
Your settings file is missing the API key or the YAML frontmatter delimiters (`---`). Ensure the file starts and ends its frontmatter with `---` lines.

**"API key does not start with 'sk-or-'"**
OpenRouter keys use the `sk-or-` prefix. Double-check you copied the full key from https://openrouter.ai/keys.

**HTTP 401 (Unauthorized)**
The API key is invalid or expired. Generate a new one at OpenRouter.

**HTTP 404 (Model not found)**
The model ID in your config doesn't match an available OpenRouter model. Check the ID at https://openrouter.ai/models.

**HTTP 429 (Rate limit exceeded)**
You've hit OpenRouter's rate limits. The script retries automatically with exponential backoff. If it persists, wait a minute or reduce the number of models.

**NETWORK_ERROR / curl failures**
Check your internet connection and DNS resolution. If you're behind a proxy or firewall, ensure `curl` can reach `https://openrouter.ai`.

**Empty responses from a model**
The model returned HTTP 200 but with no content. This occasionally happens under high load. The script retries automatically; if it persists, try a different model.

**All 3 models fail (0/3)**
Check the error details in each response, then:
1. Verify your API key and network connectivity
2. Verify model IDs in your settings file
3. Wait and retry (may be temporary rate limiting)
