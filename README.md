# Mix of Experts

Consult several AI models as expert advisors during feature development. The lead agent (Claude Code or Cursor) acts as **director**: it writes a self-contained prompt package, lets the experts ask clarifying questions, answers them, then fans out for architecture proposals or code reviews and synthesizes the results.

One repo, two fronts, one runtime:

- **Claude Code plugin**: `/moe` command, `skills/moe-workflow/`, SessionStart validation hook
- **Cursor skill**: `cursor/moe-workflow/`, installed as a symlink at `~/.cursor/skills/moe-workflow`
- **Runtime** (`scripts/`): talks to **OpenRouter** (default) or **Azure AI Foundry**, in the foreground or as a detached background job

## Overview

Instead of relying on a single model's perspective, Mix of Experts fans out prompts to multiple LLMs in parallel and synthesizes their responses into structured comparison reports. Consultation happens in rounds: `clarify` (experts ask questions and say what evidence would sharpen their answer), `architecture`, and `review`, plus `ad-hoc` for one-off questions.

## Prerequisites

- [Claude Code](https://claude.ai/claude-code) and/or [Cursor](https://cursor.com)
- One provider:
  - an [OpenRouter](https://openrouter.ai/) API key (https://openrouter.ai/keys), or
  - an Azure AI Foundry resource with chat model deployments, its endpoint and key
- `curl`, `jq`, and `bc` (`brew install jq` on macOS; `curl` and `bc` are pre-installed)
- `python3` for background jobs
- Bash 3.2+ (the macOS system bash is fine)

## Installation

### Claude Code

```bash
# Step 1: Register the plugin marketplace
claude plugin marketplace add https://github.com/michaelwiner/mix-of-experts-plugin.git

# Step 2: Install the plugin
claude plugin install mix-of-experts@michaelwiner-mix-of-experts-plugin
```

Restart Claude Code after installation for the plugin to take effect.

### Cursor

```bash
git clone https://github.com/michaelwiner/mix-of-experts-plugin.git
cd mix-of-experts-plugin
bash scripts/sync-cursor-skill.sh
```

This symlinks `~/.cursor/skills/moe-workflow` to `cursor/moe-workflow/` in your clone (so `git pull` updates the skill) and seeds `~/.cursor/mix-of-experts.local.md` if it does not exist. It never overwrites an existing settings file, and refuses to replace a `~/.cursor/skills/moe-workflow` that is a real directory. `scripts/install-cursor.sh` is an alias.

## Setup

Keys live in environment variables only. Add them to your shell profile (`~/.zshrc`, `~/.bashrc`):

```bash
# OpenRouter (default provider)
export OPENROUTER_API_KEY=sk-or-v1-your-key-here

# Azure AI Foundry
export AZURE_OPENAI_API_KEY=your-foundry-key        # AZURE_OPENAI_KEY also works
export AZURE_OPENAI_ENDPOINT=https://YOUR-RESOURCE.services.ai.azure.com
```

Then pick models and a provider in a settings file. Agents use the first one that exists:

1. `<project>/.cursor/mix-of-experts.local.md`
2. `~/.cursor/mix-of-experts.local.md`
3. `<project>/.claude/mix-of-experts-plugin.local.md`
4. `~/.claude/mix-of-experts-plugin.local.md`

Azure AI Foundry:

```markdown
---
provider: azure-foundry
models: grok-4.6-expert,DeepSeek-V4-Pro-expert,gpt-5.6-sol
max_tokens: 8000
retries: 1
---
```

OpenRouter (the file is optional if `OPENROUTER_API_KEY` is set and the default models suit you):

```markdown
---
models: openai/gpt-5.2,google/gemini-3-flash-preview,deepseek/deepseek-v3.2-20251201
---
```

See [Configuration Reference](#configuration-reference) for all options.

> **Note**: Never put keys in a settings file you might commit. `openrouter_api_key` and `azure_api_key` are still read as fallbacks, but the env vars always take priority.

### Verify

```bash
bash scripts/validate-setup.sh          # dependency + settings check (always exits 0)
bash scripts/smoke-azure-foundry.sh     # live Azure call; exit 2 = skipped (no credentials)
```

## Usage

Start the workflow with the `/moe` slash command:

```
/moe Add a real-time notification system using WebSockets
```

In Cursor, ask for it in plain words ("use mix of experts to design X") and the `moe-workflow` skill takes over.

This kicks off a 7-phase workflow:

1. **Discovery** -- Understand the feature requirements
2. **Codebase Exploration** -- Analyze relevant existing code and patterns
3. **Clarifying Questions** -- Resolve ambiguities with you, then run an expert `clarify` round: each model asks up to 3 questions and makes up to 3 context requests, and the director answers the questions and adds the requested evidence
4. **Architecture Design (MoE)** -- Fan out to all configured models for diverse architectural proposals, then synthesize into a comparison report
5. **Implementation** -- Build the feature following the chosen architecture
6. **Quality Review (MoE)** -- Fan out to all models for code review, then synthesize findings with multi-model agreement highlighted
7. **Summary** -- Document what was built and key decisions

### Clarify, then reply

The architecture round never runs on a guess. The director builds a nine-section prompt package (goal, problem, constraints, expert Q&A, codebase context, current state, success criteria, explicit ask, assumptions), sends it with `--phase clarify`, and gets two things back from each expert: **clarifying questions** (decisions) and **context requests** (the files, schemas, logs or numbers that would most sharpen their answer, and where to find them). The director answers the questions, fetches the evidence into the package, and only then sends it with `--phase architecture`. Only questions the director cannot answer from evidence come back to you. Architecture answers end by naming the missing information that would most change them, and the synthesis shows you those.

### Ad-hoc consultation

Outside the main workflow, you can ask for multi-model input at any time by requesting it during a conversation. The plugin supports an `ad-hoc` consultation phase for one-off technical questions.

## How It Works

When a consultation round runs:

1. The director writes the prompt package to a file (experts see nothing else)
2. `query-models-bg.sh` starts a detached job, so an interrupted agent turn does not kill it; `moe-status.sh` reports done / running / failed
3. `query-models.sh` sends the package to all configured models **in parallel**, retrying empty responses, rate limits and server errors
4. Each model responds with the structured sections its phase requires
5. The director reads all responses and synthesizes them, highlighting:
   - **Consensus**: where models independently agree (strong signal)
   - **Disagreements**: where models differ, with analysis of which argument is stronger
   - **Unique insights**: ideas from a single model worth considering
   - **Risk summary**: ordered by how many models flagged each risk

Background runs live in `~/.cache/moe-plugin/runs/<RUN_ID>/`. See `skills/moe-workflow/references/query-script-usage.md` for the full script reference.

## Configuration Reference

All settings go in the YAML frontmatter of the settings file.

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `provider` | No | `openrouter` | `openrouter` or `azure-foundry` |
| `models` | Azure: yes | `openai/gpt-5.2,google/gemini-3-flash-preview,deepseek/deepseek-v3.2-20251201` | Comma-separated OpenRouter IDs, or Foundry deployment names |
| `azure_endpoint` | Azure, if `AZURE_OPENAI_ENDPOINT` unset | -- | Foundry resource URL |
| `openrouter_api_key` / `azure_api_key` | No | -- | Fallbacks for the env vars (prefer the env) |
| `fallback_models` | No | -- | Comma-separated fallback models used when primary models fail after all retries |
| `max_tokens` | No | `8000` | Maximum completion tokens per model (`max_completion_tokens` on Azure) |
| `temperature` | No | `0.3` | Sampling temperature (0.0--2.0). Not sent to Azure (GPT-5.x deployments reject it) |
| `timeout` | No | `300` | Max seconds to wait per API call |
| `retries` | No | `1` | Retries on empty responses, 429, 5xx and network errors |

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

**"No API key found"**
Export `OPENROUTER_API_KEY` (or, for `provider: azure-foundry`, `AZURE_OPENAI_API_KEY` and `AZURE_OPENAI_ENDPOINT`) in the shell the agent runs in. If you use a settings file, check its frontmatter starts and ends with `---` lines.

**"provider azure-foundry requires 'models:'"**
Foundry has no default models. List your deployment names in `models:`.

**Azure HTTP 400 / 404**
Check that each `models:` entry is an exact deployment name in that resource and that the endpoint is the resource root (`https://YOUR-RESOURCE.services.ai.azure.com`, without `/openai/...`).

**Background run stuck in `running`**
`bash scripts/moe-status.sh --run-id <id>` reconciles it: if the process is gone, the run becomes `done` (a summary was written) or `failed` with `FAIL_REASON=orphaned: ...`. Details are in `~/.cache/moe-plugin/runs/<id>/stdout.log`.

**"API key does not start with 'sk-or-'"**
OpenRouter keys use the `sk-or-` prefix. Double-check you copied the full key from https://openrouter.ai/keys.

**HTTP 401 (Unauthorized)**
The API key is invalid or expired. Generate a new one at OpenRouter or in the Foundry resource.

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

## Automatic Validation

The Claude Code plugin includes a SessionStart hook (`scripts/validate-setup.sh`) that checks your setup each time Claude Code starts:

- Required dependencies (`curl`, `jq`, `bc`) are installed
- A settings file is found (same search order as above) or an env key is set
- The selected provider has what it needs: an `sk-or-` key for OpenRouter; a key, an endpoint and `models:` for Azure AI Foundry

If issues are found, a warning appears at session start. This check never blocks Claude from starting.
