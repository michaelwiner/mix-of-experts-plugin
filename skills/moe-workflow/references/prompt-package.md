# Prompt Package

Experts have no repository access, no tools, and no memory of earlier rounds. Everything they
know comes from the file passed as `--prompt-file`. Every fan-out (`clarify`, `architecture`,
`ad-hoc`, `review`) sends a package with **all nine sections, in this order, with these exact
headings**. A section with nothing to say states that explicitly (`None.`); never drop a heading.

## Template

```markdown
# MoE Prompt Package

## 1. Goal
One or two sentences: the outcome the user wants, in their terms.

## 2. Problem / feature
What is broken or missing today, who hits it, and what "working" looks like.

## 3. Constraints and non-goals
Hard constraints (stack, compatibility, budgets, deadlines, policies) and what is explicitly
out of scope, so experts don't design for it.

## 4. Expert Q&A (director answers)
See "Section 4 by round" below.

## 5. Codebase context
Only what the experts need to reason: relevant file paths with a one-line role each, key types
and signatures, short excerpts of the code that will change, existing conventions to follow.
Summarize large files; never paste secrets, keys, or `.env` contents.

## 6. Current state
What exists now, what has already been tried, and any decisions already made (and why).

## 7. Success criteria
Observable, checkable conditions: tests that must pass, behaviours, performance numbers.

## 8. Explicit ask
The single question the experts must answer, e.g. "Propose an architecture for X within the
constraints above." Written in the clarify round and then left **unchanged** for architecture.

## 9. Assumptions
What the lead is assuming but has not verified. Experts may challenge these.
```

## Section 4 by round

| Round | Section 4 content |
|---|---|
| `clarify` | Exactly: `Pending — clarify round in progress.` |
| `architecture` | Attributed Q&A and context log from the clarify round (format below), or exactly `No clarifying questions or context requests from any expert.` when every expert wrote `None` for both |
| `ad-hoc` / `review` | Any relevant Q&A, or `None.` |

Attributed Q&A format:

```markdown
**Q (grok-4.6-expert):** Does the importer need to resume after a crash, or can it restart?
**A (director):** Must resume. Jobs run up to 20 minutes and the host restarts nightly.

**Q (gpt-5.6-sol, DeepSeek-V4-Pro-expert):** Is Postgres available, or only SQLite?
**A (director, confirmed by user):** Postgres (Neon). SQLite is being retired.
```

**Context added:**
- `jobs` table schema (requested by DeepSeek-V4-Pro-expert, gpt-5.6-sol) → section 5
- p95 import duration for the last 30 days (requested by grok-4.6-expert) → section 6
- Load-test results (requested by gpt-5.6-sol) → unavailable: never run

Merge duplicate questions and requests, and list every expert who asked. Keep each answer to
10 lines or fewer. Mark answers that came from the human as `confirmed by user`. The context
log points at where the evidence landed; the evidence itself goes in sections 5–6.

## Rules

- **Section 8 is the contract.** Write it before the clarify round and do not reword it for
  the architecture round. If the ask genuinely changes, start a new clarify round.
- **Same package, additive edits.** The architecture package is the clarify package with
  section 4 filled in and requested evidence appended to sections 5–6. Nothing else is
  reworded, so the rounds stay comparable.
- **No secrets.** Packages are written to disk (`~/.cache/moe-plugin/runs/`) and sent to
  third-party providers.
- **Size.** Aim for under ~30k characters. Cut section 5 before cutting anything else.
