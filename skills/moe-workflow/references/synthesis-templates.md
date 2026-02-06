# Synthesis Templates

Templates for presenting multi-model consultation results. Follow the appropriate template based on the consultation phase.

## Architecture Synthesis Template

Use this template when presenting results from Phase 4 (Architecture Design).

```markdown
## TL;DR

[1-2 sentence summary of the recommended approach and key insight]

## Consensus & Disagreements

| Topic | GPT | Gemini | Deepseek | Verdict |
|-------|-----|--------|----------|---------|
| [topic] | [position] | [position] | [position] | AGREE / SPLIT |

## Agreement Details

[For each AGREE topic: describe the shared recommendation and why it's strong signal]

## Disagreement Analysis

### [Topic where models split]

- **GPT position**: [summary]
- **Gemini position**: [summary]
- **Deepseek position**: [summary]
- **Stronger argument**: [which model and why]
- **Resolution**: [recommended path forward]

[Repeat for each SPLIT topic]

## Unique Insights

[Ideas raised by only one model that are worth considering. Attribute each to its source model.]

## Risk Summary

| Risk | Flagged By | Severity |
|------|-----------|----------|
| [risk] | GPT, Gemini, Deepseek | [how many models flagged] |

[Order by number of models that flagged each risk, descending]

## Recommended Approach

[Opus's synthesized recommendation combining the best ideas from all models. Explain the rationale.]

## Next Steps

- [ ] [Actionable item 1]
- [ ] [Actionable item 2]
- [ ] [Actionable item 3]
```

## Review Synthesis Template

Use this template when presenting results from Phase 6 (Quality Review).

```markdown
## TL;DR

[Overall assessment: "Code is [solid/has concerns/needs work]." + critical issue count]

## Critical Issues

| # | Issue | File | Flagged By | Description |
|---|-------|------|-----------|-------------|
| 1 | [title] | [file:line] | GPT, Gemini | [description] |

[If none: "No critical issues identified."]

## Warnings

| # | Issue | File | Flagged By | Description |
|---|-------|------|-----------|-------------|
| 1 | [title] | [file:line] | Deepseek | [description] |

[If none: "No warnings identified."]

## Suggestions

| # | Issue | File | Flagged By | Description |
|---|-------|------|-----------|-------------|
| 1 | [title] | [file:line] | GPT | [description] |

[If none: "No suggestions identified."]

## Multi-Model Agreement

[List issues flagged by 2+ models. These deserve highest attention.]

## Unique Catches

[Issues found by only one model. Still valuable — single-model catches often reveal blind spots.]

## Model Confidence

| Model | Confidence | Notes |
|-------|-----------|-------|
| GPT | HIGH/MEDIUM/LOW | [any caveats] |
| Gemini | HIGH/MEDIUM/LOW | [any caveats] |
| Deepseek | HIGH/MEDIUM/LOW | [any caveats] |

## Recommended Actions

- [ ] [Fix critical issue #1]
- [ ] [Fix critical issue #2]
- [ ] [Address warning #1]
- [ ] [Consider suggestion #1]
```

## Edge Case Handling

Apply these rules when model responses don't fit neatly into the templates:

### Unstructured response (missing expected `##` sections)

Interpret the response by its meaning rather than its formatting. Extract the relevant information and map it into the template fields. Add a footnote:

> **Note**: [Model name] returned an unstructured response. The information above was extracted by interpreting the response content.

### 2 out of 3 models succeed

Use the full template but mark the failed model's columns as "N/A". Add a note at the top:

> **Note**: Only 2/3 models returned responses. Synthesis confidence is reduced. Consider re-running if the failed model's perspective is important.

### 1 out of 3 models succeed

Do not use the synthesis template. Instead, present the single response directly with a caveat:

> **Note**: Only 1/3 models returned a response. This is a single perspective, not a multi-model synthesis. Treat with appropriate skepticism and consider re-running the consultation.

### 0 out of 3 models succeed

Report all failures with their error details. Suggest:
1. Check the API key and network connectivity
2. Verify model IDs in the settings file
3. Retry after a brief wait (may be rate limiting)
