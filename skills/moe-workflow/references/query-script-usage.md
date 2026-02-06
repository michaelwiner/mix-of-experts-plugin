# Query Script Usage

The `query-models.sh` script sends a prompt to multiple AI models via OpenRouter in parallel and writes each response to a separate file.

## Location

```
${CLAUDE_PLUGIN_ROOT}/scripts/query-models.sh
```

## Synopsis

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/query-models.sh \
  --settings-file <path> \
  --phase <phase> \
  --prompt-file <path> \
  [--no-cache]
```

## Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `--settings-file` | Yes | Path to the `.local.md` settings file containing OpenRouter API key and model config |
| `--phase` | Yes | Consultation phase: `architecture`, `review`, or `ad-hoc` |
| `--prompt-file` | Yes | Path to a text file containing the prompt to send to all models |
| `--no-cache` | No | Skip the response cache and force fresh API calls |

## Phase-Specific Behavior

Each phase sets a tailored system prompt that requests structured output with specific `##` sections:

- **`architecture`**: Models act as senior software architects. Required sections: `## Summary`, `## Key Claims` (numbered list), `## Implementation Detail`, `## Risks and Trade-offs`, `## Confidence` (HIGH/MEDIUM/LOW)
- **`review`**: Models act as senior code reviewers. Required sections: `## Summary`, `## Critical Issues`, `## Warnings`, `## Suggestions` (each with "None identified." if empty), `## Confidence`
- **`ad-hoc`**: Models act as senior engineers. Required sections: `## Summary`, `## Analysis`, `## Alternatives Considered`, `## Confidence`
- **default**: Light-touch prompt requesting a 2-3 sentence summary followed by detailed analysis

## Output

The script prints:
1. `OUTPUT_DIR=/path/to/temp/dir` — the directory containing response files
2. `MODEL_RESPONSES:` — list of response file paths with status (`OK`, `FAIL`, `CACHE`)
3. `SUMMARY:` — success/fail/cache counts and total cost (if available)

Each response file is named after the model (slashes replaced with underscores):
- `openai_gpt-5.2.md`
- `google_gemini-3-flash-preview.md`
- `deepseek_deepseek-v3.2-20251201.md`

## Response File Format

Successful response:
```markdown
# Response from openai/gpt-5.2

**Tokens**: prompt=1234, completion=567
**Attempts**: 1
**Cost**: $0.0012

---

[Model's response content here]
```

Error response:
```markdown
# ERROR from openai/gpt-5.2

**HTTP Status**: 429

\```
{"error": {"message": "Rate limit exceeded"}}
\```
```

## Caching

Responses are cached in `~/.cache/moe-plugin/` by a hash of the phase, model, temperature, max_tokens, and prompt content. On subsequent runs with the same parameters, cached responses are served instantly without API calls.

- Cache hits are shown as `CACHE` in the output
- Use `--no-cache` to bypass the cache and force fresh API calls
- Cached responses include cost data from the original API call
- To clear the cache: `rm -rf ~/.cache/moe-plugin/`

## Cost Tracking

After all models respond, the script queries the OpenRouter generation endpoint for cost data. Per-model costs are inserted into response file headers as `**Cost**: $X.XXXX`, and the total cost is shown in the summary line.

Cost data depends on OpenRouter's generation endpoint being available. If cost lookup fails for a model, the response is still valid — only the cost line is omitted.

## Workflow Integration

### Step 1: Write the prompt to a temp file

```bash
# The skill instructs Opus to write a detailed prompt file before calling the script
```

### Step 2: Call the script

```bash
RESULT=$(bash ${CLAUDE_PLUGIN_ROOT}/scripts/query-models.sh \
  --settings-file ".claude/mix-of-experts-plugin.local.md" \
  --phase "architecture" \
  --prompt-file "/tmp/moe-prompt.md")
```

### Step 3: Read responses

Parse `OUTPUT_DIR` from the result, then read each response file.

## Dependencies

- `curl` — HTTP client for API calls
- `jq` — JSON parsing (must be installed)
- `bash` 4+ — for parallel execution

## Error Handling

- Missing settings file: exits with error message
- Missing API key: exits with error message
- API errors (rate limits, invalid model, etc.): captured in response file with HTTP status
- Timeout: each request has a configurable max timeout (default 300 seconds)
- Individual model failures do not block other models (parallel execution)
