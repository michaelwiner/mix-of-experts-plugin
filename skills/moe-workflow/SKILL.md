---
name: MoE Feature Development Workflow
description: This skill should be used when the user asks to "build a feature with multiple models", "use mix of experts", "get opinions from different AI models", "moe workflow", "feature dev with expert consultation", invokes the "/moe" command, or wants to leverage multiple LLM providers (GPT, Gemini, Deepseek, Grok via OpenRouter or Azure AI Foundry) for architecture design or code review during feature development.
version: 0.2.1
---

# Mix of Experts Feature Development

A structured feature development workflow where Claude acts as the lead architect (the **director**), consulting external AI models (via OpenRouter or Azure AI Foundry) at high-value decision points. The workflow follows a phased approach: understand the codebase, clarify requirements with the user and then with the experts, gather diverse architectural opinions from multiple models, implement, and review with multi-model feedback.

Experts have no repository access. Everything they know comes from the **prompt package** the director writes (`references/prompt-package.md`).

## Prerequisites

Locate the settings file. Use the first one that exists and pass it as `--settings-file` (the scripts do not search on their own):

1. `<project>/.cursor/mix-of-experts.local.md`
2. `~/.cursor/mix-of-experts.local.md`
3. `<project>/.claude/mix-of-experts-plugin.local.md`
4. `~/.claude/mix-of-experts-plugin.local.md`

The file selects the `provider` (`openrouter`, the default, or `azure-foundry`) and the `models`. Keys come from the environment: `OPENROUTER_API_KEY`, or `AZURE_OPENAI_API_KEY` (alias `AZURE_OPENAI_KEY`) plus `AZURE_OPENAI_ENDPOINT`. With OpenRouter and the env key set, the file is optional. If nothing is configured, ask the user to set it up per `references/settings-template.md`. Never write keys into a settings file or a prompt package.

At the start of every workflow, run the setup check yourself (the SessionStart hook does not fire reliably for every install type) and fix anything it reports before consulting:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/validate-setup.sh" < /dev/null
```

Script paths used below:

```bash
QUERY_BG="${CLAUDE_PLUGIN_ROOT}/scripts/query-models-bg.sh"
QUERY="${CLAUDE_PLUGIN_ROOT}/scripts/query-models.sh"
STATUS="${CLAUDE_PLUGIN_ROOT}/scripts/moe-status.sh"
```

## Workflow Phases

### Phase 1: Discovery

**Goal**: Understand what needs to be built.

1. Create a todo list tracking all 7 phases
2. If the feature is unclear, ask:
   - What problem does this solve?
   - What should the feature do?
   - Any constraints or requirements?
3. Summarize understanding and confirm with user

### Phase 2: Codebase Exploration

**Goal**: Understand relevant existing code and patterns.

1. Launch 2-3 code-explorer agents in parallel, each targeting a different aspect:
   - Similar features and their implementation patterns
   - Architecture, abstractions, and control flow
   - UI patterns, testing approaches, extension points
2. Each agent should return a list of 5-10 key files
3. Read all key files identified by agents
4. Present comprehensive summary of findings

### Phase 3: Clarifying Questions (user, then experts)

**Goal**: Resolve all ambiguities before designing.

**Do not skip this phase.**

1. Review codebase findings and the original feature request
2. Identify underspecified aspects: edge cases, error handling, integration points, scope, design preferences, performance needs
3. Present your own questions to the user in a clear, organized list and wait for answers
4. Build the prompt package per `references/prompt-package.md`: all nine sections, section 8 is the explicit ask, section 4 is exactly `Pending — clarify round in progress.` Write it to a file
   - Section 1 needs the goal **and up to 150 words on the product**: what it is, who uses it, the domain rules and invariants any design must respect, its scale and stage, and how this ask fits. Read `CLAUDE.md`, `AGENTS.md` and `README.md` (and the code) for this rather than guessing — experts know nothing about the product beyond what you write
   - Reuse that same product paragraph verbatim in every later round
5. Run the expert clarify round (see **Running a consultation** below) with `--phase clarify`
6. Act as director, following `references/clarify-qa.md`. Experts return both **Clarifying Questions** (decisions) and **Context Requests** (evidence that would sharpen their answer, with where to find it):
   - Answer questions in 10 lines or fewer each; escalate to the user only what you cannot answer from evidence (in one batch)
   - Fetch the requested evidence you can get and add concise excerpts to sections 5–6; record anything unavailable, never invent it
7. Fill section 4 with the attributed Q&A and context log, or `No clarifying questions or context requests from any expert.` if every expert answered `None` to both. Do not reword section 8

### Phase 4: Architecture Design (MoE Consultation)

**Goal**: Gather diverse architectural proposals from multiple AI models.

This is the primary MoE consultation point. Each external model brings a different perspective and problem-solving approach.

**Hard gate**: do not run this phase while section 4 of the package still says `Pending`, and do not reword section 8. The architecture package is the clarify package with section 4 filled and requested evidence added to sections 5–6.

1. Run the consultation with `--phase architecture` and the same package file

2. Read each model's response from `RESPONSES_DIR`. For each response, check:
   - If the file starts with `# ERROR` — record as a failed model
   - If the response is missing expected `## Summary` or `## Key Claims` sections — flag as unstructured

3. Count successful responses and apply the appropriate presentation:
   - **3/3 or 2/3 succeed**: Follow the **Architecture Synthesis Template** from `references/synthesis-templates.md`
   - **1/3 succeeds**: Present the single response directly with a reduced-confidence caveat (see edge cases in the templates file)
   - **0/3 succeed**: Report all failures, suggest troubleshooting steps

4. When using the Architecture Synthesis Template:
   - Build the Consensus & Disagreements table by comparing each model's **Key Claims** section
   - Mark unstructured responses with a footnote (extract information by meaning)
   - Mark failed models as "N/A" in table columns
   - Note which clarify answers and added context shaped the proposals
   - List the missing information the experts named at the end of `## Confidence`, most-cited first, so the user knows what would firm up the decision

5. Present the completed synthesis report to the user
6. Ask the user which approach to pursue before proceeding to implementation

### Phase 5: Implementation

**Goal**: Build the feature following the chosen architecture.

**Do not start without explicit user approval.**

1. Read all relevant files identified in previous phases
2. Implement following the chosen architecture
3. Follow codebase conventions strictly
4. Update todos as progress is made

### Phase 6: Quality Review (MoE Consultation)

**Goal**: Get diverse review perspectives from multiple models.

This is the second MoE consultation point.

1. Gather all modified/created files
2. Prepare a review package (same nine sections; section 5 carries the diffs or full files, section 8 asks for a review against the success criteria) containing:
   - Original requirements
   - Chosen architecture rationale
   - All code changes (diffs or full files)
   - Specific review focus areas

3. Run the consultation with `--phase review`

4. Read each model's review from the output files. For each response, check:
   - If the file starts with `# ERROR` — record as a failed model
   - If the response is missing expected `## Critical Issues` or `## Warnings` sections — flag as unstructured

5. Count successful responses and apply the appropriate presentation:
   - **3/3 or 2/3 succeed**: Follow the **Review Synthesis Template** from `references/synthesis-templates.md`
   - **1/3 succeeds**: Present the single review directly with a reduced-confidence caveat
   - **0/3 succeed**: Report all failures, suggest troubleshooting steps

6. When using the Review Synthesis Template:
   - Merge identical issues raised by multiple models into single entries, listing all flagging models in the "Flagged By" column
   - Highlight multi-model agreement prominently — these issues deserve highest attention
   - Unique single-model catches are still valuable and should be included

7. Present the completed review synthesis report to the user
8. Ask what to fix: fix now, fix later, or proceed as-is
9. Address issues based on user decision

### Phase 7: Summary

**Goal**: Document what was accomplished.

1. Mark all todos complete
2. Summarize:
   - What was built
   - Key decisions made and which models influenced them
   - Files modified/created
   - Notable insights from the multi-model consultation
   - Suggested next steps

## Ad-Hoc MoE Consultation

Outside of Phases 3, 4 and 6, consult external models when:
- Facing a genuinely difficult technical decision with no clear answer
- The user explicitly requests multi-model input
- Encountering an unfamiliar domain where diverse perspectives would help

Use `--phase "ad-hoc"` with a full prompt package.

## Running a consultation

Prefer the background runner: a fan-out takes minutes, and a detached job survives an interrupted turn.

```bash
bash "$QUERY_BG" \
  --settings-file "<settings file from Prerequisites>" \
  --phase "clarify" \
  --prompt-file "/path/to/package.md"
# prints RUN_ID, RUN_DIR, PID

bash "$STATUS" --run-id "<RUN_ID>"   # exit 0 = done, 2 = running, 1 = failed
```

Poll while the status exits 2. On 0, read every `RESPONSES_DIR/*.md`. On 1, read `FAIL_REASON` and `RUN_DIR/stdout.log`; a run whose process died without a summary is marked `orphaned`.

**Cost gate.** If the launch exits **3** (`COST_GATE: estimated $X exceeds max_cost_usd ...`), nothing ran. Tell the user the estimate and ask; re-run with `--confirm-cost` only if they agree. After every run, report the `Cost:` from the `SUMMARY` line.

**Truncated answers.** A response marked `**Status**: TRUNCATED` was cut off even after a retry with double the tokens. Use what it contains, but treat its missing sections as absent and say so in the synthesis.

**Web search: two modes.** Check the `**Web searches**:` line in each response header.
- *With search* (`web_search` on for the round, OpenRouter): experts searched up to `web_search_max` times and list `## Web Sources`. Prefer sourced claims; with conflicting sources, prefer the newer or official one and say so; check any remaining `(unverified)` product claims yourself before recommending them.
- *Without search* (off, or `azure-foundry`, where the header says `none (requested, but not available ...)`): experts answer from training data and are told to mark current-facts claims (versions, availability, pricing) `(unverified)`. **You** are the only one who can check them: verify those claims with your own tools before the synthesis, and say in the synthesis which ones you checked. Never present an `(unverified)` claim as fact.
- Suggest `web_search: architecture,review` on OpenRouter when the ask depends on current third-party services or versions, and not for confidential code.

**Dev styles.** Each expert answers through one professional lens (`**Style**:` in its header: `ship`, `scale`, or `simplify`). Use this in the synthesis: a risk raised only by `scale` is an ops risk, not a disagreement about the design.

The foreground script (`bash "$QUERY" ...`, same flags) blocks until every model answers and prints `OUTPUT_DIR`; use it only for quick checks, and never interrupt it.

## Script Reference

`query-models.sh` handles:
- Reading settings (provider, models, limits) from the settings file and keys from the env
- Sending the package to all configured models in parallel, with per-phase system prompts
- Retrying empty responses, 429s, 5xx and network errors with a retry addendum
- Writing each model's response to a separate file and printing a `SUMMARY:` line

`query-models-bg.sh` wraps it as a detached job under `~/.cache/moe-plugin/runs/<RUN_ID>/`, and `moe-status.sh` reports on it.

See `references/query-script-usage.md` for detailed script documentation.

## Settings File Format

The settings file uses YAML frontmatter in a `.local.md` file. See `references/settings-template.md` for the complete format and configuration options.

## Tips for Effective MoE Consultation

- **Be specific in prompts**: Vague questions get vague answers. Include concrete code context.
- **Summarize codebase context**: External models lack project knowledge. Section 5 of the package must give them enough to reason about the architecture.
- **Weight multi-model agreement**: When multiple models independently suggest the same approach, it is a strong signal.
- **Value unique perspectives**: A single model catching a security issue or suggesting an elegant pattern is worth attention even if others missed it.
- **Keep prompts focused**: One clear question per consultation yields better results than broad requests.
