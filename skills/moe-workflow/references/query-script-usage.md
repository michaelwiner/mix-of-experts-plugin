# Query Script Usage

Three scripts, one runtime:

| Script | Purpose |
|---|---|
| `query-models.sh` | Foreground fan-out: sends one prompt package to every configured model in parallel |
| `query-models-bg.sh` | Runs `query-models.sh` as a detached background job (preferred for agents) |
| `moe-status.sh` | Reports on a background job; exit code says done / running / failed |

Locations: `${CLAUDE_PLUGIN_ROOT}/scripts/` under Claude Code, `~/.cursor/skills/moe-workflow/scripts/` under Cursor.

## query-models.sh

```bash
bash query-models.sh \
  --settings-file <path> \
  --phase <architecture|review|clarify|ad-hoc> \
  --prompt-file <path> \
  [--no-cache] [--confirm-cost] [--estimate-only]
```

| Argument | Required | Description |
|----------|----------|-------------|
| `--settings-file` | Yes | `.local.md` settings file (see `settings-template.md`). May be absent on disk for OpenRouter when `OPENROUTER_API_KEY` is set |
| `--phase` | Yes | `architecture`, `review`, `clarify`, or `ad-hoc`. Anything else exits 1 |
| `--prompt-file` | Yes | The prompt package (see `prompt-package.md`) |
| `--no-cache` | No | Skip the response cache and force fresh API calls |
| `--confirm-cost` | No | Run even if the cost estimate is above `max_cost_usd` (only after the user agreed) |
| `--estimate-only` | No | Print the cost estimate and gate result, call no models |

Exit codes: `0` ran (read `SUMMARY`), `1` error, `3` cost gate (see below).

### Phases

Each phase sets a system prompt that requires specific `##` sections:

- **`clarify`**: `## Summary`, `## Clarifying Questions` (decisions only the operator/user can make; up to 3, at most 5 if essential; exactly `None` if nothing needs asking), `## Context Requests` (up to 3 pieces of evidence the operator should add to the package, each with why it would change the recommendation and where to find it; exactly `None` if the package is sufficient), `## Confidence`. No architecture is produced in this phase.
- **`architecture`**: `## Summary`, `## Key Claims` (numbered), `## Implementation Detail`, `## Risks and Trade-offs`, `## Confidence` (ends with the single piece of missing information that would most change the proposal)
- **`review`**: `## Summary`, `## Critical Issues`, `## Warnings`, `## Suggestions` (each `None identified.` if empty), `## Confidence`
- **`ad-hoc`**: `## Summary`, `## Analysis`, `## Alternatives Considered`, `## Confidence` (ends with the most valuable missing information, as for architecture)

### Providers

| | `openrouter` (default) | `azure-foundry` |
|---|---|---|
| URL | `https://openrouter.ai/api/v1/chat/completions` | `{endpoint}/openai/v1/chat/completions` |
| Auth | `Authorization: Bearer $OPENROUTER_API_KEY` | `api-key: $AZURE_OPENAI_API_KEY` (or `AZURE_OPENAI_KEY`) |
| Token limit field | `max_tokens` | `max_completion_tokens` |
| `temperature` | Sent | Omitted (GPT-5.x deployments reject it) |
| Model names | `provider/model` | Deployment names (`[A-Za-z0-9._-]+`), `models:` required |
| Cost | Inline `usage.cost`, plus pre-run estimate and gate | Not available |

### Dev styles

Each expert's system prompt starts with one professional lens from `styles:` (default
`ship,scale,simplify`, assigned by model position). See `settings-template.md`.

### Web search

With `web_search` enabled for the phase (OpenRouter only), each request carries
`tools: [{type: "openrouter:web_search", parameters: {max_uses: <web_search_max>, engine: <web_search_engine>}}]`
and the system prompt tells the expert what searches are for. Each response then has
`**Web searches**: N of MAX (engine)` in its header and a `## Web Sources` list of the cited
URLs at the end. Web search settings are part of the cache key.

### Cost

- **Before the run (OpenRouter):** the script prices one full-length (`max_tokens`) answer per
  uncached model from OpenRouter's public model list and prints `Estimated max cost: $X`.
  If that is above `max_cost_usd` (default `$0.50`), it prints
  `COST_GATE: estimated $X exceeds max_cost_usd $Y ...` and exits **3** without calling any
  model. Ask the user; re-run with `--confirm-cost` only if they agree.
- **After the run:** the real cost comes from each response's `usage.cost`, including paid
  retries, and appears per model (`**Cost**:`) and in `SUMMARY: ... | Cost: $X`.
- Azure Foundry publishes no per-call price, so it has no estimate, gate, or cost line.

### Truncation

A response that stops because it hit the token cap (`finish_reason: length`) is retried once
with `max_tokens` doubled. If it is still cut off it is kept, labelled
`**Status**: TRUNCATED` in its header and `TRUNC` in the output, counted in the summary
(`N truncated`), and never cached. Treat its missing trailing sections as absent, not empty.

### Retries

Empty responses, HTTP 429, HTTP 5xx and network errors are retried up to `retries` times
(default 1) with backoff `2^attempt` seconds, or the server's `Retry-After` (capped at 60s)
when it sends one, as Azure does for per-minute token limits. Other 4xx errors fail
immediately, as does `finish_reason: content_filter` (`**Status**: CONTENT_FILTERED`). On every
retry the system prompt gets an addendum that restates the contract (every required section,
no meta commentary, mark Confidence LOW if unsure), because the usual failure is an empty or
truncated answer.

### Output

1. `OUTPUT_DIR=/path/to/temp/dir` — directory containing the response files
2. `MODEL_RESPONSES:` — each file with status `OK`, `TRUNC`, `CACHE`, `FAIL` or `MISS`
3. `SUMMARY: N succeeded[ (T truncated, C cached)], F failed, M total[ | Cost: $X]`

Response files are named after the model with `/` replaced by `_`
(`openai_gpt-5.6-sol.md`, `grok-4.6-expert.md`).

Successful response:
```markdown
# Response from openai/gpt-5.6-sol

**Provider**: openrouter
**Style**: ship
**Tokens**: prompt=1234, completion=567
**Attempts**: 1
**Cost**: $0.0012

---

[Model's response content here]
```

Error response:
```markdown
# ERROR from openai/gpt-5.6-sol

**HTTP Status**: 429
**Attempts**: 2

\```
Rate limit exceeded
\```
```

### Caching

Responses are cached in `~/.cache/moe-plugin/` keyed by provider, phase, model, style, temperature,
max_tokens, and hashes of the prompt file and the phase's system prompt. Truncated answers are
never cached. Cache hits show as `CACHE`. Use `--no-cache` to
bypass; `rm -rf ~/.cache/moe-plugin/*.md` clears it (leaving background runs alone).

## query-models-bg.sh

Same flags as `query-models.sh` (except `--estimate-only`), plus `--run-id <id>` (default: timestamp, phase, and PID). Requires `python3`.

Before detaching it runs a synchronous preflight (`--estimate-only`): bad settings exit 1 and
the cost gate exits 3 immediately, with the same messages, so nothing is launched that would
only fail later.

```bash
bash query-models-bg.sh --settings-file "$S" --phase clarify --prompt-file "$PKG"
# RUN_ID=20260919-142501-clarify-4242
# RUN_DIR=/Users/you/.cache/moe-plugin/runs/20260919-142501-clarify-4242
# PID=4251
# Poll: bash .../moe-status.sh --run-id 20260919-142501-clarify-4242
```

The job is started with `subprocess.Popen(..., start_new_session=True, close_fds=True)`, so it
survives the agent turn (or terminal) that launched it being interrupted.

`RUN_DIR` (`~/.cache/moe-plugin/runs/<RUN_ID>/`) contains:

| File | Meaning |
|---|---|
| `prompt.md` | Snapshot of the prompt package (safe to delete the original) |
| `phase`, `started_at` | Run metadata |
| `status` | `running`, `done` or `failed` |
| `pid` | PID of the detached wrapper |
| `run.sh`, `launch.py` | The wrapper and the detach launcher |
| `stdout.log` | Full output of `query-models.sh` (stdout and stderr) |
| `responses/*.md` | Copies of every response file |
| `summary` | The `SUMMARY:` line |
| `exit_code` | Exit code of `query-models.sh` |
| `output_dir` | The original `OUTPUT_DIR` |
| `fail_reason` | Why the run failed (only when it did) |

`status` becomes `done` only when the summary shows at least one success
(`SUMMARY: [1-9][0-9]* succeeded`); a clean exit with zero answers is `failed`.

Pointers to the newest run: `runs/latest` (a file containing the `RUN_DIR` path) and
`runs/latest-link` (a symlink).

## moe-status.sh

```bash
bash moe-status.sh --run-id <id>     # or --latest, or no arguments (= latest)
```

| Exit | Meaning |
|---|---|
| 0 | `done` — read `RESPONSES_DIR/*.md` |
| 2 | `running` — poll again in 20–30 s |
| 1 | `failed`, or no such run |

Prints `RUN_ID`, `RUN_DIR`, `STATUS`, `PHASE`, `STARTED_AT`, `PID`, `PID_ALIVE`, the `SUMMARY`
line, `FAIL_REASON` (when failed), `RESPONSES_DIR`, and each response file.

**Orphans.** If `status` says `running` but the PID is gone (reboot, OOM, `kill -9`), the status
is reconciled: with a successful `SUMMARY` in `summary` or `stdout.log` the run is marked `done`
(and responses copied if missing); otherwise it is marked `failed` with
`FAIL_REASON=orphaned: ...` and `exit_code` 137.

## Dependencies

- `curl`, `jq`, `bc` — required by `query-models.sh`
- `python3` — required only by `query-models-bg.sh`
- Bash 3.2+ (the macOS system bash works)

## Input validation

- `provider`: `openrouter` or `azure-foundry`
- `max_tokens`, `timeout`: positive integers; `retries`: non-negative integer
- `temperature`: number between 0.0 and 2.0
- Model names: `provider/model` for OpenRouter, deployment names for Azure

Invalid values exit 1 before any API call.

## Smoke test (Azure)

```bash
AZURE_OPENAI_ENDPOINT=https://YOUR-RESOURCE.services.ai.azure.com \
AZURE_OPENAI_API_KEY=... \
bash scripts/smoke-azure-foundry.sh      # optional: AZURE_DEPLOYMENTS=a,b,c
```

Exit 0 = at least one deployment answered, 1 = failed, 2 = skipped (credentials not set).
