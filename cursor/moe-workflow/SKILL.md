---
name: moe-workflow
description: Consult several external LLMs (Azure AI Foundry or OpenRouter) as expert advisors — clarify, then architecture, then optional code review — and synthesize their answers. Use when the user asks for "mix of experts", "MoE", "ask other models", "multi-model architecture/review", or wants second opinions on a design or diff.
---

# Mix of Experts (Cursor)

You are the **director**. Experts are external models with no repo access: they only see the
prompt package you write. You gather context, run the rounds, answer their questions, and
synthesize. You never hand the decision to the experts, and you never implement without the
user's approval.

## Paths

```bash
MOE_SKILL_DIR="$HOME/.cursor/skills/moe-workflow"
QUERY_BG="$MOE_SKILL_DIR/scripts/query-models-bg.sh"
QUERY="$MOE_SKILL_DIR/scripts/query-models.sh"
STATUS="$MOE_SKILL_DIR/scripts/moe-status.sh"
```

## Settings

Use the first file that exists and pass it as `--settings-file` (the scripts do not search):

1. `<project>/.cursor/mix-of-experts.local.md`
2. `~/.cursor/mix-of-experts.local.md`
3. `<project>/.claude/mix-of-experts-plugin.local.md`
4. `~/.claude/mix-of-experts-plugin.local.md`

Typical file:

```yaml
---
provider: azure-foundry
models: grok-4.6-expert,DeepSeek-V4-Pro-expert,gpt-5.6-sol
max_tokens: 8000
retries: 1
---
```

Secrets come from the env only: `AZURE_OPENAI_API_KEY` (or `AZURE_OPENAI_KEY`) plus
`AZURE_OPENAI_ENDPOINT`, or `OPENROUTER_API_KEY` for `provider: openrouter`. Never write keys
into a settings file or a prompt package. Details: `references/settings-template.md`.

## Workflow

0. **Check setup:** `bash "$MOE_SKILL_DIR/scripts/validate-setup.sh" < /dev/null`; fix what it reports.
1. **Understand.** Read the relevant code; ask the user only what the code cannot tell you.
2. **Build the prompt package** (`references/prompt-package.md`): all nine sections, section 8
   is the big ask, section 4 is `Pending — clarify round in progress.` Write it to a file.
   Section 1 carries the goal **and up to 150 words on the product**: what it is, who uses it,
   the domain rules and invariants any design must respect, scale and stage, and how this ask
   fits. Take it from `CLAUDE.md` / `AGENTS.md` / `README.md` and the code, never from guesses —
   the experts know nothing else about the product. Reuse it verbatim in later rounds.
3. **Clarify round:** `bash "$QUERY_BG" --settings-file "$S" --phase clarify --prompt-file "$PKG"`
4. **Act on the clarify round** as director (`references/clarify-qa.md`). Experts return
   questions (decisions) and context requests (evidence that would sharpen their answer):
   answer questions in ≤10 lines, escalate to the user only what you cannot answer, fetch
   the requested evidence into sections 5–6. Log both in section 4.
5. **Architecture round:** same command with `--phase architecture` and the same package.
6. **Synthesize** with `references/synthesis-templates.md`: consensus, disagreements (and
   which argument is stronger), unique insights, risks, and the missing information experts
   named in `## Confidence` that would most change the decision.
7. **Challenge round** (after an approach is chosen, before building): add the chosen design to
   section 6, point section 8 at it, and run `--phase challenge` with `--models` set to one model
   that did not write that design. It is instructed to oppose: read `## The Case Against` and the
   `## Post-Mortem`, say which objections land, and fold them in. Agreement in the earlier rounds
   is the reason to run this, not a reason to skip it.
8. **Stop for approval.** Present the synthesis, the challenge, and your recommendation; wait for the user.
9. **Optional review round** after implementing: package with the diff, `--phase review`.

`--phase ad-hoc` takes the same full package for one-off questions outside this flow.

### Hard gates

- Never run `architecture` while section 4 still says `Pending`, unless every expert answered
  `None` to both questions and context requests (section 4 then says so).
- Never change section 8 between clarify and architecture.
- Never implement before the user approves the synthesis.

## Running and polling

Prefer the background runner. It detaches, so an interrupted agent turn does not kill the job:

```bash
bash "$QUERY_BG" --settings-file "$S" --phase clarify --prompt-file "$PKG"   # prints RUN_ID
bash "$STATUS" --run-id "$RUN_ID"     # 0 = done, 2 = running, 1 = failed
```

Poll every 20–30 s while it returns 2. On 0, read every `RESPONSES_DIR/*.md`. On 1, read
`FAIL_REASON` and `RUN_DIR/stdout.log`, fix the cause, and re-run. A run whose process died
without a summary is reported as `orphaned`.

Use `bash "$QUERY" ...` (foreground) only for quick checks. Never interrupt a foreground run.

- **Exit 3 / `COST_GATE`:** nothing ran. Ask the user about the estimate; re-run with
  `--confirm-cost` only if they agree. Always report `Cost:` from the `SUMMARY` line.
- **`**Status**: TRUNCATED`:** cut off even after a doubled-token retry. Use it, but say which
  sections are missing.
- **Web search** (see `**Web searches**:` in each header). *With search* (OpenRouter,
  `web_search` on): prefer claims backed by `## Web Sources`; with conflicting sources prefer the
  newer or official one. *Without search* (off, or Azure): experts mark current-facts claims
  `(unverified)`; verify them yourself before the synthesis and never present them as fact.
  Suggest `web_search: architecture,review` when the ask depends on current services or
  versions; not for confidential code.
- **`**Style**:`** (`ship` / `scale` / `simplify`): each expert's professional lens. A point
  raised only through one lens is a perspective, not necessarily a disagreement.

## Reading responses

- A file starting with `# ERROR` is a failed expert: record it and carry on with the others.
- A response missing its required `##` sections is unstructured: use it, but footnote it.
- 1 of N succeeded: present it with a reduced-confidence caveat. 0 of N: report the errors.

Install or update: `bash <clone>/scripts/sync-cursor-skill.sh` (symlinks this directory).
Script reference: `references/query-script-usage.md`.
