# Mix of Experts

Get a second, third and fourth opinion on your design and your code from other AI models, without leaving Claude Code or Cursor.

Your agent (Claude Code or Cursor) acts as the **director**. It writes a self-contained brief, sends it to several models in parallel (GPT, Gemini, DeepSeek, Grok, ... via **OpenRouter** or **Azure AI Foundry**), lets them ask clarifying questions, answers them, and then merges their proposals or reviews into one report: where they agree, where they disagree and who has the better argument, and which risks several of them flagged.

- **Claude Code**: installs as a plugin with a `/moe` command
- **Cursor**: installs as a skill; ask for "mix of experts" in chat
- **Cost**: typically $0.01–$0.10 per round on OpenRouter. It's shown after every run, and a run estimated above $1 stops and asks first

---

## Quick start (about 5 minutes)

### 1. Check the tools

macOS and most Linux distros already have what's needed except, sometimes, `jq`:

```bash
brew install jq          # or: sudo apt-get install jq
```

Required: `bash` (3.2+; the macOS default works), `curl`, `jq`, `bc`, and `python3` for background runs.

### 2. Get an API key

Pick **one** provider:

| Provider | What you need |
|---|---|
| **OpenRouter** (default, easiest) | A key from [openrouter.ai/keys](https://openrouter.ai/keys) with a few dollars of credit. Gives access to GPT, Gemini, DeepSeek, Grok and more from one key |
| **Azure AI Foundry** | A Foundry resource with chat model deployments, plus its key and endpoint (**Keys and Endpoint** in the Azure portal) |

Add the key to your shell profile (`~/.zshrc` or `~/.bashrc`), **never** to a file in a repo:

```bash
# OpenRouter
export OPENROUTER_API_KEY=sk-or-v1-...

# or Azure AI Foundry
export AZURE_OPENAI_API_KEY=...                                   # AZURE_OPENAI_KEY also works
export AZURE_OPENAI_ENDPOINT=https://YOUR-RESOURCE.services.ai.azure.com
```

Then open a new terminal, and **restart Claude Code or Cursor** so they see the variable.

### 3. Install

<details open>
<summary><b>Claude Code</b></summary>

```bash
claude plugin marketplace add https://github.com/michaelwiner/mix-of-experts-plugin.git
claude plugin install mix-of-experts@mix-of-experts
```

Restart Claude Code. At startup it checks your setup and warns if anything is missing.

</details>

<details open>
<summary><b>Cursor</b></summary>

```bash
git clone https://github.com/michaelwiner/mix-of-experts-plugin.git ~/mix-of-experts-plugin
bash ~/mix-of-experts-plugin/scripts/sync-cursor-skill.sh
```

This links `~/.cursor/skills/moe-workflow` to the clone (so a `git pull` updates it) and creates `~/.cursor/mix-of-experts.local.md` with sensible defaults for whichever key you exported. It never overwrites an existing settings file.

</details>

### 4. Check the setup

```bash
# Cursor
bash ~/.cursor/skills/moe-workflow/scripts/validate-setup.sh < /dev/null

# Claude Code
bash ~/.claude/plugins/cache/mix-of-experts/mix-of-experts/*/scripts/validate-setup.sh < /dev/null
```

You want: `[MoE Plugin] Setup OK`. Anything else is a warning that says what to fix. (Both skills also run this check whenever the workflow starts.)

### 5. First run

**Claude Code:**

```
/moe Add rate limiting to our public API
```

**Cursor** (in the agent chat):

```
Use mix of experts to design rate limiting for our public API
```

The agent explores your code, asks you what it can't work out, runs a clarify round and then an architecture round with the experts, and shows you a synthesis. **It won't write code until you approve an approach.**

For a quick one-off opinion instead of the full workflow, ask for it in plain words: *"ask the experts whether we should use Postgres advisory locks or Redis for this"*.

---

## What happens during a run

```
You describe the feature
   │
   ▼
Director explores the code and asks you what it can't work out
   │
   ▼
Clarify round ─ each expert asks ≤3 questions and says what evidence it needs
   │            (files, schemas, logs); the director answers and adds that evidence
   ▼
Architecture round ─ each expert proposes a design through its own lens
   │
   ▼
Synthesis ─ consensus, disagreements, unique ideas, risks → you pick an approach
   │
   ▼
Implementation → optional Review round on the diff → summary
```

- **Experts see only the brief.** They have no access to your repo. The director writes a nine-section *prompt package* (goal, problem, constraints, Q&A, code context, current state, success criteria, the ask, assumptions); see `skills/moe-workflow/references/prompt-package.md`.
- **Different lenses.** By default each expert argues from one professional style: `ship` (pragmatic startup engineer), `scale` (staff/SRE), `simplify` (principal maintainer).
- **Runs in the background.** Rounds take a minute or two and run as detached jobs, so an interrupted agent turn doesn't lose them.
- **Honest failures.** An answer cut off by the token limit is retried with a bigger budget and flagged `TRUNCATED` if it's still cut off; a failed model is reported as failed, never silently dropped.
- **Optional web search** (OpenRouter): let experts check current facts such as versions, deprecations and pricing, at most 3 searches each by default, with cited sources. Off by default.

---

## Settings

Settings live in the YAML front matter of a `.local.md` file. The agent uses the **first** one that exists:

1. `<your project>/.cursor/mix-of-experts.local.md`
2. `~/.cursor/mix-of-experts.local.md`
3. `<your project>/.claude/mix-of-experts-plugin.local.md`
4. `~/.claude/mix-of-experts-plugin.local.md`

With OpenRouter and `OPENROUTER_API_KEY` set, **no file is needed**. The defaults are GPT-5.2, Gemini 3 Flash and DeepSeek V3.2.

**Recommended (OpenRouter):**

```markdown
---
models: openai/gpt-5.2,google/gemini-3-flash-preview,deepseek/deepseek-v3.2-20251201
web_search: architecture,review
max_cost_usd: 1
---
```

**Azure AI Foundry:**

```markdown
---
provider: azure-foundry
models: grok-4.6-expert,DeepSeek-V4-Pro-expert,gpt-5.6-sol
---
```

On Azure, `models` are **your deployment names**, not model IDs. Use the resource endpoint (`https://<resource>.services.ai.azure.com`), not a project endpoint. Web search isn't available on Azure.

**Cheaper clarify rounds** (any round can have its own models):

```markdown
---
models: openai/gpt-5.2,google/gemini-3-pro-preview,deepseek/deepseek-v3.2-20251201
models_clarify: google/gemini-3-flash-preview,deepseek/deepseek-v3.2-20251201
---
```

Add `*.local.md` settings to `.gitignore`. Keys belong in environment variables, not in these files.

### All options

| Field | Default | Description |
|-------|---------|-------------|
| `provider` | `openrouter` | `openrouter` or `azure-foundry` |
| `models` | GPT-5.2, Gemini 3 Flash, DeepSeek V3.2 | Comma-separated OpenRouter IDs, or Foundry deployment names (required on Azure) |
| `models_<phase>` | -- | Per-round override, e.g. `models_clarify:`. Phases: `clarify`, `architecture`, `review`, `ad-hoc` |
| `fallback_models` | -- | Used when a primary model fails after its retries |
| `styles` | `ship,scale,simplify` | One professional lens per expert, in model order; `off` to disable |
| `web_search` | `off` | `on`, `off`, or rounds (e.g. `architecture,review`). OpenRouter only |
| `web_search_max` | `3` | Max searches per expert per call (enforced by OpenRouter) |
| `web_search_engine` | `exa` | `exa` (~$0.007/search), `auto`, `native`, `parallel`, `perplexity` |
| `max_cost_usd` | `1` | A run estimated above this asks for confirmation first (OpenRouter) |
| `max_tokens` | `8000` | Max answer length per expert (includes reasoning tokens on reasoning models) |
| `temperature` | `0.3` | 0.0–2.0. Not sent to Azure (its reasoning models reject it) |
| `timeout` | `300` | Seconds per API call |
| `retries` | `1` | Retries on empty answers, rate limits, 5xx and network errors |
| `azure_endpoint` | -- | Alternative to `AZURE_OPENAI_ENDPOINT` |
| `openrouter_api_key` / `azure_api_key` | -- | Fallbacks for the env vars. Prefer the env vars |

Browse OpenRouter model IDs at [openrouter.ai/models](https://openrouter.ai/models). Mixing vendors (e.g. OpenAI + Google + DeepSeek) gives more independent opinions than several models from one family.

---

## Updating and uninstalling

| | Update | Uninstall |
|---|---|---|
| **Claude Code** | `claude plugin marketplace update mix-of-experts` then `claude plugin update mix-of-experts@mix-of-experts` | `claude plugin uninstall mix-of-experts@mix-of-experts` |
| **Cursor** | `git -C ~/mix-of-experts-plugin pull` (the skill is a symlink, so that's all) | `rm ~/.cursor/skills/moe-workflow` (removes only the link) |

Restart the app after updating.

---

## Troubleshooting

**"No API key found" even though I exported it**
The app was started before the variable existed, or from somewhere that doesn't read your shell profile. Open a new terminal, check `echo $OPENROUTER_API_KEY`, and restart Claude Code or Cursor (or start it from that terminal).

**`/moe` doesn't exist in Claude Code**
Restart Claude Code after installing, and check `claude plugin list` shows `mix-of-experts@mix-of-experts`.

**Cursor doesn't use the skill**
Check `ls ~/.cursor/skills/moe-workflow/SKILL.md`, then ask explicitly: *"use the moe-workflow skill"*. If `sync-cursor-skill.sh` said the target "is not a symlink", move the old `~/.cursor/skills/moe-workflow` directory aside and run it again.

**"COST_GATE: estimated $X exceeds max_cost_usd"**
Nothing ran. The agent should ask you; if you agree it re-runs with `--confirm-cost`. Raise `max_cost_usd` if your rounds are routinely bigger.

**An expert shows `TRUNCATED`**
Its answer hit `max_tokens` even after a retry with double the budget. Raise `max_tokens` (reasoning models spend part of it thinking).

**"provider azure-foundry requires 'models:'"**
Foundry has no default models. List your deployment names in `models:`.

**Azure HTTP 401 / 404**
401 with an endpoint containing `/api/projects/`: use the resource endpoint `https://<resource>.services.ai.azure.com` (project endpoints expect Entra ID tokens). 404: check each `models:` entry is an exact deployment name in that resource.

**`CONTENT_FILTERED`**
The provider's content filter blocked the answer. Rephrase; the same prompt would be blocked again, so it isn't retried.

**HTTP 429 (rate limit)**
Retried automatically, waiting as long as the provider asks (up to 60s). If it persists, use fewer models or wait a minute.

**A background run is stuck in `running`**
`bash <scripts>/moe-status.sh --run-id <id>` reconciles it: a run whose process is gone becomes `done` (if a summary was written) or `failed` with `FAIL_REASON=orphaned`. Logs are in `~/.cache/moe-plugin/runs/<id>/stdout.log`.

**All experts fail**
Read the `# ERROR` files the run lists: usually a wrong model ID (check [openrouter.ai/models](https://openrouter.ai/models)), no credit left on the key, or a network block on `openrouter.ai` / your Azure endpoint.

---

## For contributors

One repo serves both tools:

| Path | What it is |
|---|---|
| `scripts/` | The runtime, shared by both: `query-models.sh` (fan-out), `query-models-bg.sh` + `moe-status.sh` (background runs), `validate-setup.sh`, `smoke-azure-foundry.sh`, `sync-cursor-skill.sh` |
| `skills/moe-workflow/` | The Claude Code skill, plus `references/` shared with Cursor |
| `cursor/moe-workflow/` | The Cursor skill (`scripts` and `references` are symlinks) |
| `commands/moe.md`, `hooks/`, `.claude-plugin/` | Claude Code plugin wiring |

Full script reference: [`skills/moe-workflow/references/query-script-usage.md`](skills/moe-workflow/references/query-script-usage.md). Azure live check: `bash scripts/smoke-azure-foundry.sh` (exit 2 = skipped, no credentials).
