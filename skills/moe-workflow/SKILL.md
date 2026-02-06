---
name: MoE Feature Development Workflow
description: This skill should be used when the user asks to "build a feature with multiple models", "use mix of experts", "get opinions from different AI models", "moe workflow", "feature dev with expert consultation", invokes the "/moe" command, or wants to leverage multiple LLM providers (GPT, Gemini, Deepseek) for architecture design or code review during feature development.
version: 0.1.0
---

# Mix of Experts Feature Development

A structured feature development workflow where Opus acts as the lead architect, consulting external AI models (via OpenRouter) at high-value decision points. The workflow follows a phased approach: understand the codebase, clarify requirements, gather diverse architectural opinions from multiple models, implement, and review with multi-model feedback.

## Prerequisites

Before starting, read the user's MoE settings file at `.claude/mix-of-experts-plugin.local.md` in the project root (or `~/.claude/mix-of-experts-plugin.local.md` for global config). This file contains the OpenRouter API key and model configuration. If the file does not exist, ask the user to create one. See `references/settings-template.md` for the required format.

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

### Phase 3: Clarifying Questions

**Goal**: Resolve all ambiguities before designing.

**Do not skip this phase.**

1. Review codebase findings and the original feature request
2. Identify underspecified aspects: edge cases, error handling, integration points, scope, design preferences, performance needs
3. Present all questions in a clear, organized list
4. Wait for answers before proceeding

### Phase 4: Architecture Design (MoE Consultation)

**Goal**: Gather diverse architectural proposals from multiple AI models.

This is the primary MoE consultation point. Each external model brings a different perspective and problem-solving approach.

1. Prepare a context package containing:
   - Feature description and requirements
   - Relevant codebase patterns discovered in Phase 2
   - User's answers from Phase 3
   - Key file contents (summarized if large)

2. Call the query script to fan out to all configured models:
   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/query-models.sh \
     --settings-file ".claude/mix-of-experts-plugin.local.md" \
     --phase "architecture" \
     --prompt-file "/path/to/prompt.md"
   ```

   Before calling the script, write the prompt to a temporary file. The prompt should ask each model to propose an architecture with:
   - Implementation approach and rationale
   - File structure and key components
   - Trade-offs and risks
   - Estimated complexity

3. Read each model's response from the output files. For each response, check:
   - If the file starts with `# ERROR` — record as a failed model
   - If the response is missing expected `## Summary` or `## Key Claims` sections — flag as unstructured

4. Count successful responses and apply the appropriate presentation:
   - **3/3 or 2/3 succeed**: Follow the **Architecture Synthesis Template** from `references/synthesis-templates.md`
   - **1/3 succeeds**: Present the single response directly with a reduced-confidence caveat (see edge cases in the templates file)
   - **0/3 succeed**: Report all failures, suggest troubleshooting steps

5. When using the Architecture Synthesis Template:
   - Build the Consensus & Disagreements table by comparing each model's **Key Claims** section
   - Mark unstructured responses with a footnote (extract information by meaning)
   - Mark failed models as "N/A" in table columns

6. Present the completed synthesis report to the user
7. Ask the user which approach to pursue before proceeding to implementation

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
2. Prepare a review prompt containing:
   - Original requirements
   - Chosen architecture rationale
   - All code changes (diffs or full files)
   - Specific review focus areas

3. Call the query script:
   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/query-models.sh \
     --settings-file ".claude/mix-of-experts-plugin.local.md" \
     --phase "review" \
     --prompt-file "/path/to/review-prompt.md"
   ```

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

Outside of Phases 4 and 6, consult external models when:
- Facing a genuinely difficult technical decision with no clear answer
- The user explicitly requests multi-model input
- Encountering an unfamiliar domain where diverse perspectives would help

To consult, use the same query script with `--phase "ad-hoc"`.

## Script Reference

The query script at `${CLAUDE_PLUGIN_ROOT}/scripts/query-models.sh` handles:
- Reading settings (API key, models) from the settings file
- Sending prompts to all configured models via OpenRouter in parallel
- Writing each model's response to separate output files
- Returning the paths to output files

See `references/query-script-usage.md` for detailed script documentation.

## Settings File Format

The settings file uses YAML frontmatter in a `.local.md` file. See `references/settings-template.md` for the complete format and configuration options.

## Tips for Effective MoE Consultation

- **Be specific in prompts**: Vague questions get vague answers. Include concrete code context.
- **Summarize codebase context**: External models lack project knowledge. Provide enough context to reason about the architecture.
- **Weight multi-model agreement**: When multiple models independently suggest the same approach, it is a strong signal.
- **Value unique perspectives**: A single model catching a security issue or suggesting an elegant pattern is worth attention even if others missed it.
- **Keep prompts focused**: One clear question per consultation yields better results than broad requests.
