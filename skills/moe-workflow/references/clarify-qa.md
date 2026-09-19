# Clarify, then Architecture

Experts design better when they can ask first. The architecture fan-out is therefore always
preceded by a `clarify` round on the same prompt package (see `prompt-package.md`).

The clarify round gives the director two kinds of guidance:

- **Clarifying Questions**: decisions only a person can make (intent, priorities, trade-offs).
  The director answers them.
- **Context Requests**: evidence the experts say would most sharpen their conclusion (a file,
  a schema, a log, a benchmark, a prior attempt), each with why it matters and where to find
  it. The director fetches it and adds it to the package. This is how the experts tell the
  operator what to look at, not just what to decide.

## Flow

1. **Build the package** with sections 1–3 and 5–9 filled. Section 8 holds the big ask.
   Section 4 is exactly `Pending — clarify round in progress.`
2. **Fan out `--phase clarify`.** Each expert returns `## Summary`, `## Clarifying Questions`,
   `## Context Requests` and `## Confidence`. Experts ask at most 3 questions (5 only if
   essential) and make at most 3 context requests, or write `None` for either. They do not
   propose an architecture in this round.
3. **Director answers.** The lead agent (the director) merges duplicate questions and answers
   each one in 10 lines or fewer, from the codebase, the conversation, and the package.
   Escalate to the human **only** for questions the director cannot answer from evidence
   (product decisions, priorities, access, money). Ask those in one batch, not one at a time.
4. **Director gathers context.** Rank the merged context requests by how many experts asked
   and how much they say it would change the answer. Fetch each one you can (read the file,
   run the query, grep the logs) and add a concise excerpt to section 5 (code, schemas,
   interfaces) or section 6 (logs, metrics, prior attempts). Anything you cannot get is
   recorded as unavailable with a reason; never invent it. Requests that turn out to be
   decisions (e.g. "which SLA applies?") become questions for step 3.
5. **Fill section 4** with the attributed Q&A and a context log (format in
   `prompt-package.md`), or `No clarifying questions or context requests from any expert.`
   if every expert wrote `None` for both. Section 8 stays word-for-word.
6. **Fan out `--phase architecture`** with the updated package.
7. **Surface what is still missing.** Each architecture answer ends its `## Confidence` with
   the single piece of missing information that would most change it. Put the recurring ones
   in the synthesis, so the user sees what would firm up the decision.

## Hard gate

Never run `--phase architecture` while section 4 still says `Pending`. The only exception is
when every expert in the clarify round answered `None` to both sections, and then section 4
must say so.

## Handling clarify responses

| Response | Action |
|---|---|
| Questions listed | Merge, answer, attribute |
| Context requests listed | Merge, rank, fetch into sections 5–6, log in section 4 |
| `None` (both sections) | Record; counts toward the "all None" exception |
| `# ERROR` file | Treat as no questions; note the failure in the synthesis |
| Proposes an architecture anyway | Extract any implicit questions; ignore the design |

## Example

```bash
# Round 1
bash "$QUERY_BG" --settings-file "$SETTINGS" --phase clarify --prompt-file "$PKG"
bash "$STATUS" --latest            # poll until exit 0, read RESPONSES_DIR/*.md

# Director answers questions in section 4, adds requested evidence to sections 5-6

# Round 2
bash "$QUERY_BG" --settings-file "$SETTINGS" --phase architecture --prompt-file "$PKG"
bash "$STATUS" --latest
```
